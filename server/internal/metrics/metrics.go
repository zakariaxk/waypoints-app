// Package metrics is a small, dependency-free registry of counters, gauges, and
// histograms rendered in the Prometheus text exposition format (version 0.0.4).
//
// All metric types are safe for concurrent use and lock-free on the hot path
// (atomic adds only). The registry lock is taken only when registering a metric
// and when rendering.
package metrics

import (
	"fmt"
	"io"
	"math"
	"net/http"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Labels are constant labels attached to one series. Several series may share a
// name if their labels differ; they render under one HELP and TYPE line.
type Labels map[string]string

func (l Labels) render(extra ...string) string {
	if len(l) == 0 && len(extra) == 0 {
		return ""
	}
	keys := make([]string, 0, len(l))
	for k := range l {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys)+len(extra)/2)
	for _, k := range keys {
		parts = append(parts, k+"="+strconv.Quote(l[k]))
	}
	for i := 0; i+1 < len(extra); i += 2 {
		parts = append(parts, extra[i]+"="+strconv.Quote(extra[i+1]))
	}
	return "{" + strings.Join(parts, ",") + "}"
}

type kind string

const (
	kindCounter   kind = "counter"
	kindGauge     kind = "gauge"
	kindHistogram kind = "histogram"
)

type series interface {
	write(w io.Writer, name string, labels Labels)
}

type entry struct {
	labels Labels
	s      series
}

type family struct {
	help    string
	kind    kind
	entries []entry
}

// Registry holds every metric of one process.
type Registry struct {
	mu       sync.Mutex
	families map[string]*family
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{families: map[string]*family{}}
}

func (r *Registry) add(name, help string, k kind, labels Labels, s series) {
	r.mu.Lock()
	defer r.mu.Unlock()
	f, ok := r.families[name]
	if !ok {
		f = &family{help: help, kind: k}
		r.families[name] = f
	}
	if f.kind != k {
		panic(fmt.Sprintf("metrics: %s registered as %s and %s", name, f.kind, k))
	}
	want := labels.render()
	for _, e := range f.entries {
		if e.labels.render() == want {
			panic(fmt.Sprintf("metrics: duplicate series %s%s", name, want))
		}
	}
	f.entries = append(f.entries, entry{labels: labels, s: s})
}

// Counter is a monotonically increasing count.
type Counter struct{ v atomic.Uint64 }

func (c *Counter) Inc()          { c.v.Add(1) }
func (c *Counter) Add(n uint64)  { c.v.Add(n) }
func (c *Counter) Value() uint64 { return c.v.Load() }
func (c *Counter) write(w io.Writer, name string, l Labels) {
	fmt.Fprintf(w, "%s%s %d\n", name, l.render(), c.v.Load())
}

// Counter registers and returns a counter.
func (r *Registry) Counter(name, help string, labels Labels) *Counter {
	c := &Counter{}
	r.add(name, help, kindCounter, labels, c)
	return c
}

// Gauge is a value that goes up and down.
type Gauge struct{ v atomic.Int64 }

func (g *Gauge) Set(v int64)  { g.v.Store(v) }
func (g *Gauge) Add(d int64)  { g.v.Add(d) }
func (g *Gauge) Inc()         { g.v.Add(1) }
func (g *Gauge) Dec()         { g.v.Add(-1) }
func (g *Gauge) Value() int64 { return g.v.Load() }
func (g *Gauge) write(w io.Writer, name string, l Labels) {
	fmt.Fprintf(w, "%s%s %d\n", name, l.render(), g.v.Load())
}

// Gauge registers and returns a gauge.
func (r *Registry) Gauge(name, help string, labels Labels) *Gauge {
	g := &Gauge{}
	r.add(name, help, kindGauge, labels, g)
	return g
}

type gaugeFunc func() float64

func (f gaugeFunc) write(w io.Writer, name string, l Labels) {
	fmt.Fprintf(w, "%s%s %s\n", name, l.render(), formatFloat(f()))
}

// GaugeFunc registers a gauge whose value is read by calling fn at render time.
// fn must be safe to call from any goroutine.
func (r *Registry) GaugeFunc(name, help string, labels Labels, fn func() float64) {
	r.add(name, help, kindGauge, labels, gaugeFunc(fn))
}

// CounterFunc registers a counter whose value is read by calling fn at render time.
func (r *Registry) CounterFunc(name, help string, labels Labels, fn func() float64) {
	r.add(name, help, kindCounter, labels, gaugeFunc(fn))
}

// Histogram counts observations into fixed, cumulative buckets.
type Histogram struct {
	bounds []float64
	counts []atomic.Uint64 // len(bounds)+1; the last is +Inf
	sum    atomic.Uint64   // float64 bits
	count  atomic.Uint64
}

// Observe records one value.
func (h *Histogram) Observe(v float64) {
	i := sort.SearchFloat64s(h.bounds, v) // first bound >= v
	h.counts[i].Add(1)
	h.count.Add(1)
	for {
		old := h.sum.Load()
		if h.sum.CompareAndSwap(old, math.Float64bits(math.Float64frombits(old)+v)) {
			return
		}
	}
}

// ObserveDuration records d in seconds.
func (h *Histogram) ObserveDuration(d time.Duration) { h.Observe(d.Seconds()) }

func (h *Histogram) write(w io.Writer, name string, l Labels) {
	var cum uint64
	for i, b := range h.bounds {
		cum += h.counts[i].Load()
		fmt.Fprintf(w, "%s_bucket%s %d\n", name, l.render("le", formatFloat(b)), cum)
	}
	cum += h.counts[len(h.bounds)].Load()
	fmt.Fprintf(w, "%s_bucket%s %d\n", name, l.render("le", "+Inf"), cum)
	fmt.Fprintf(w, "%s_sum%s %s\n", name, l.render(), formatFloat(math.Float64frombits(h.sum.Load())))
	fmt.Fprintf(w, "%s_count%s %d\n", name, l.render(), cum)
}

// Histogram registers and returns a histogram with the given upper bounds,
// which must be sorted ascending.
func (r *Registry) Histogram(name, help string, labels Labels, bounds []float64) *Histogram {
	if !sort.Float64sAreSorted(bounds) {
		panic("metrics: histogram bounds must be sorted: " + name)
	}
	h := &Histogram{bounds: append([]float64(nil), bounds...), counts: make([]atomic.Uint64, len(bounds)+1)}
	r.add(name, help, kindHistogram, labels, h)
	return h
}

// LatencyBuckets suit durations in seconds from 100 µs to 10 s.
var LatencyBuckets = []float64{0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

// SizeBuckets suit counts and byte sizes from 1 to about 1 MB.
var SizeBuckets = []float64{1, 4, 16, 64, 256, 1024, 4096, 16384, 65536, 262144, 1048576}

// Render writes every metric in the Prometheus text format, sorted by name.
func (r *Registry) Render(w io.Writer) {
	r.mu.Lock()
	names := make([]string, 0, len(r.families))
	for n := range r.families {
		names = append(names, n)
	}
	sort.Strings(names)
	type snap struct {
		name string
		f    family
	}
	snaps := make([]snap, 0, len(names))
	for _, n := range names {
		f := r.families[n]
		snaps = append(snaps, snap{n, family{help: f.help, kind: f.kind, entries: append([]entry(nil), f.entries...)}})
	}
	r.mu.Unlock()

	for _, s := range snaps {
		fmt.Fprintf(w, "# HELP %s %s\n# TYPE %s %s\n", s.name, s.f.help, s.name, s.f.kind)
		for _, e := range s.f.entries {
			e.s.write(w, s.name, e.labels)
		}
	}
}

// Handler serves the registry over HTTP.
func (r *Registry) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		r.Render(w)
	})
}

// RegisterRuntime adds process and Go runtime gauges.
func (r *Registry) RegisterRuntime() {
	start := float64(time.Now().UnixNano()) / 1e9
	r.GaugeFunc("process_start_time_seconds", "Start time of the process since the Unix epoch in seconds.", nil,
		func() float64 { return start })
	r.GaugeFunc("go_goroutines", "Number of goroutines that currently exist.", nil,
		func() float64 { return float64(runtime.NumGoroutine()) })
	r.GaugeFunc("go_gomaxprocs", "Value of GOMAXPROCS.", nil,
		func() float64 { return float64(runtime.GOMAXPROCS(0)) })

	// MemStats is read at most once per render via a small cache so the three
	// gauges below cost one stop-the-world, not three.
	var (
		mu   sync.Mutex
		ms   runtime.MemStats
		read time.Time
	)
	mem := func(f func(*runtime.MemStats) float64) func() float64 {
		return func() float64 {
			mu.Lock()
			defer mu.Unlock()
			if time.Since(read) > time.Second {
				runtime.ReadMemStats(&ms)
				read = time.Now()
			}
			return f(&ms)
		}
	}
	r.GaugeFunc("go_memstats_heap_alloc_bytes", "Bytes of allocated heap objects.", nil,
		mem(func(m *runtime.MemStats) float64 { return float64(m.HeapAlloc) }))
	r.GaugeFunc("go_memstats_sys_bytes", "Bytes of memory obtained from the OS.", nil,
		mem(func(m *runtime.MemStats) float64 { return float64(m.Sys) }))
	r.CounterFunc("go_gc_cycles_total", "Completed GC cycles.", nil,
		mem(func(m *runtime.MemStats) float64 { return float64(m.NumGC) }))
	r.CounterFunc("go_gc_pause_seconds_total", "Total stop-the-world GC pause time in seconds.", nil,
		mem(func(m *runtime.MemStats) float64 { return float64(m.PauseTotalNs) / 1e9 }))
}

func formatFloat(v float64) string {
	switch {
	case math.IsInf(v, 1):
		return "+Inf"
	case math.IsInf(v, -1):
		return "-Inf"
	case math.IsNaN(v):
		return "NaN"
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}
