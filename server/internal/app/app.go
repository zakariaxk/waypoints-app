// Package app holds the gateway's process-wide pieces: configuration, logger,
// metrics, the two HTTP muxes, a typed service registry, and the lifecycle.
//
// Every other internal package exposes Register(*App). cmd/gateway calls them
// in a fixed order; a package wires itself in from Register by mounting
// handlers on Mux, providing services with Provide, and adding OnStart, OnStop,
// and Go hooks. Nothing starts listening until Run.
package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/http/pprof"
	"os"
	"reflect"
	"sync"
	"sync/atomic"
	"time"

	"waypoints/server/internal/metrics"
)

type hook struct {
	name string
	fn   func(ctx context.Context) error
}

type task struct {
	name string
	fn   func(ctx context.Context)
}

// App is the gateway process.
type App struct {
	Config  Config
	Log     *slog.Logger
	Metrics *metrics.Registry

	// Mux serves the public listener (Config.Addr): /healthz, /v1/..., /internal/....
	Mux *http.ServeMux
	// DebugMux serves the private listener (Config.MetricsAddr): /metrics and /debug/pprof/.
	DebugMux *http.ServeMux

	mu       sync.Mutex
	services map[reflect.Type]any
	starts   []hook
	stops    []hook
	tasks    []task
	running  bool

	wg       sync.WaitGroup
	draining atomic.Bool
	done     chan struct{}
}

// New builds an App from cfg. It does not start anything.
func New(cfg Config) *App {
	opts := &slog.HandlerOptions{Level: cfg.LogLevel}
	var h slog.Handler
	if cfg.LogFormat == "json" {
		h = slog.NewJSONHandler(os.Stderr, opts)
	} else {
		h = slog.NewTextHandler(os.Stderr, opts)
	}

	a := &App{
		Config:   cfg,
		Log:      slog.New(h).With("node", cfg.Node),
		Metrics:  metrics.NewRegistry(),
		Mux:      http.NewServeMux(),
		DebugMux: http.NewServeMux(),
		services: map[reflect.Type]any{},
		done:     make(chan struct{}),
	}
	a.Metrics.RegisterRuntime()

	a.Mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		if a.draining.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte("draining\n"))
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})

	a.DebugMux.Handle("GET /metrics", a.Metrics.Handler())
	a.DebugMux.HandleFunc("/debug/pprof/", pprof.Index)
	a.DebugMux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	a.DebugMux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	a.DebugMux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	a.DebugMux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	return a
}

// OnStart adds a hook run, in registration order, after both listeners are
// bound and before serving begins. An error aborts startup.
func (a *App) OnStart(name string, fn func(ctx context.Context) error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.mustNotRun("OnStart")
	a.starts = append(a.starts, hook{name, fn})
}

// OnStop adds a hook run, in reverse registration order, during shutdown,
// after the HTTP servers stop accepting. ctx carries the shutdown deadline.
// Use it to close long-lived connections (WebSockets are hijacked, so
// http.Server.Shutdown does not wait for them) and flush state.
func (a *App) OnStop(name string, fn func(ctx context.Context) error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.mustNotRun("OnStop")
	a.stops = append(a.stops, hook{name, fn})
}

// Go adds a background goroutine started by Run after the start hooks. Its
// ctx is cancelled when shutdown begins; shutdown waits for it to return
// (bounded by the shutdown deadline).
func (a *App) Go(name string, fn func(ctx context.Context)) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.mustNotRun("Go")
	a.tasks = append(a.tasks, task{name, fn})
}

// Draining reports whether shutdown has begun.
func (a *App) Draining() bool { return a.draining.Load() }

// Done is closed when shutdown begins.
func (a *App) Done() <-chan struct{} { return a.done }

func (a *App) mustNotRun(what string) {
	if a.running {
		panic("app: " + what + " called after Run")
	}
}

// Provide stores v as the process-wide instance of T, so that one package can
// hand a service to another that registers later (for example the hub to ws).
// Providing the same T twice panics.
func Provide[T any](a *App, v T) {
	t := reflect.TypeFor[T]()
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, dup := a.services[t]; dup {
		panic(fmt.Sprintf("app: %v provided twice", t))
	}
	a.services[t] = v
}

// Lookup returns the instance of T stored by Provide.
func Lookup[T any](a *App) (T, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	v, ok := a.services[reflect.TypeFor[T]()]
	if !ok {
		var zero T
		return zero, false
	}
	return v.(T), true
}

// MustLookup is Lookup that panics when T was not provided; use it in Register
// when registration order guarantees the provider ran first.
func MustLookup[T any](a *App) T {
	v, ok := Lookup[T](a)
	if !ok {
		panic(fmt.Sprintf("app: %v not provided (check Register order in cmd/gateway)", reflect.TypeFor[T]()))
	}
	return v
}

// Run binds both listeners, runs start hooks, starts background tasks, and
// serves until ctx is cancelled or a server fails. It then shuts down within
// Config.ShutdownTimeout: /healthz turns 503, task contexts are cancelled, the
// HTTP servers drain, stop hooks run, and tasks are awaited.
func (a *App) Run(ctx context.Context) error {
	a.mu.Lock()
	a.mustNotRun("Run")
	a.running = true
	a.mu.Unlock()

	pubLn, err := net.Listen("tcp", a.Config.Addr)
	if err != nil {
		return fmt.Errorf("listen %s: %w", a.Config.Addr, err)
	}
	dbgLn, err := net.Listen("tcp", a.Config.MetricsAddr)
	if err != nil {
		pubLn.Close()
		return fmt.Errorf("listen %s: %w", a.Config.MetricsAddr, err)
	}

	runCtx, cancelRun := context.WithCancel(context.WithoutCancel(ctx))
	defer cancelRun()

	for _, h := range a.starts {
		if err := h.fn(runCtx); err != nil {
			pubLn.Close()
			dbgLn.Close()
			return fmt.Errorf("start %s: %w", h.name, err)
		}
	}

	errLog := slog.NewLogLogger(a.Log.Handler(), slog.LevelWarn)
	pub := &http.Server{Handler: a.Mux, ReadHeaderTimeout: 10 * time.Second, ErrorLog: errLog,
		BaseContext: func(net.Listener) context.Context { return runCtx }}
	dbg := &http.Server{Handler: a.DebugMux, ReadHeaderTimeout: 10 * time.Second, ErrorLog: errLog}

	serveErr := make(chan error, 2)
	serve := func(s *http.Server, ln net.Listener) {
		if err := s.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serveErr <- err
		}
	}
	go serve(pub, pubLn)
	go serve(dbg, dbgLn)

	for _, t := range a.tasks {
		a.wg.Add(1)
		go func() {
			defer a.wg.Done()
			defer func() {
				if r := recover(); r != nil {
					a.Log.Error("task panicked", "task", t.name, "panic", r)
				}
			}()
			t.fn(runCtx)
		}()
	}

	a.Log.Info("gateway serving", "addr", pubLn.Addr().String(), "metrics", dbgLn.Addr().String(), "env", a.Config.Env)

	var runErr error
	select {
	case <-ctx.Done():
		a.Log.Info("shutdown requested")
	case runErr = <-serveErr:
		a.Log.Error("server failed", "err", runErr)
	}

	return errors.Join(runErr, a.shutdown(cancelRun, pub, dbg))
}

func (a *App) shutdown(cancelRun context.CancelFunc, pub, dbg *http.Server) error {
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), a.Config.ShutdownTimeout)
	defer cancel()

	a.draining.Store(true)
	close(a.done)
	cancelRun()

	var errs []error
	if err := pub.Shutdown(ctx); err != nil {
		errs = append(errs, fmt.Errorf("public server: %w", err))
		pub.Close()
	}
	for i := len(a.stops) - 1; i >= 0; i-- {
		h := a.stops[i]
		if err := h.fn(ctx); err != nil {
			errs = append(errs, fmt.Errorf("stop %s: %w", h.name, err))
		}
	}

	waited := make(chan struct{})
	go func() { a.wg.Wait(); close(waited) }()
	select {
	case <-waited:
	case <-ctx.Done():
		errs = append(errs, errors.New("background tasks did not finish before the shutdown deadline"))
	}

	// The debug listener goes last so /metrics stays scrapeable while draining.
	if err := dbg.Shutdown(ctx); err != nil {
		dbg.Close()
	}

	err := errors.Join(errs...)
	if err != nil {
		a.Log.Warn("shutdown finished with errors", "took", time.Since(start).Round(time.Millisecond), "err", err)
	} else {
		a.Log.Info("shutdown complete", "took", time.Since(start).Round(time.Millisecond))
	}
	return err
}
