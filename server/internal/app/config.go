package app

import (
	"bufio"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config is the gateway's process configuration, read from the environment.
// Every variable is documented in server/README.md; keep the two in step.
//
// Packages that need a variable not listed here read it with Env, EnvInt,
// EnvBool, or EnvDuration and document it in server/README.md.
type Config struct {
	Env             string        // WAYPOINTS_ENV: dev, bench, or prod
	Addr            string        // WAYPOINTS_ADDR, or ":"+PORT
	MetricsAddr     string        // WAYPOINTS_METRICS_ADDR
	Node            string        // WAYPOINTS_NODE
	LogLevel        slog.Level    // WAYPOINTS_LOG_LEVEL
	LogFormat       string        // WAYPOINTS_LOG_FORMAT: text or json
	ShutdownTimeout time.Duration // WAYPOINTS_SHUTDOWN_TIMEOUT

	SupabaseURL            string // SUPABASE_URL
	SupabaseServiceRoleKey string // SUPABASE_SERVICE_ROLE_KEY
	DatabaseURL            string // DATABASE_URL
	NATSURL                string // NATS_URL; empty means single-node mode

	LiveKitURL       string // LIVEKIT_URL
	LiveKitAPIKey    string // LIVEKIT_API_KEY
	LiveKitAPISecret string // LIVEKIT_API_SECRET

	APNsKeyID   string // APNS_KEY_ID
	APNsTeamID  string // APNS_TEAM_ID
	APNsKeyPath string // APNS_KEY_PATH
	APNsTopic   string // APNS_TOPIC
	APNsEnv     string // APNS_ENV: sandbox or production

	InternalSecret string // WAYPOINTS_INTERNAL_SECRET, shared with the pg_net trigger
	BenchSecret    string // WAYPOINTS_BENCH_SECRET, HS256 key accepted only with -bench
	MaxConns       int    // WAYPOINTS_MAX_CONNS, cap on open realtime connections
}

// IsBench reports whether the process runs in the benchmark environment.
func (c Config) IsBench() bool { return c.Env == "bench" }

// LoadConfig reads the environment. If a .env file exists in the working
// directory (or at WAYPOINTS_ENV_FILE), its variables are applied first,
// without overriding anything already set in the real environment.
func LoadConfig() (Config, error) {
	if err := loadDotEnv(); err != nil {
		return Config{}, err
	}

	host, _ := os.Hostname()
	if host == "" {
		host = "gateway"
	}
	addr := ":8080"
	if p := os.Getenv("PORT"); p != "" {
		addr = ":" + p
	}

	// WAYPOINTS_ENV fails closed: unset or empty means prod, so a deployment
	// that forgets the variable gets production behaviour, never the dev
	// backdoors (HS256 dev tokens, /dev/* seeding, in-memory store).
	env := Env("WAYPOINTS_ENV", "prod")

	c := Config{
		Env:         env,
		Addr:        Env("WAYPOINTS_ADDR", addr),
		MetricsAddr: Env("WAYPOINTS_METRICS_ADDR", "127.0.0.1:9090"),
		Node:        Env("WAYPOINTS_NODE", host),

		SupabaseURL:            Env("SUPABASE_URL", ""),
		SupabaseServiceRoleKey: Env("SUPABASE_SERVICE_ROLE_KEY", ""),
		DatabaseURL:            Env("DATABASE_URL", ""),
		NATSURL:                Env("NATS_URL", ""),

		LiveKitURL:       Env("LIVEKIT_URL", ""),
		LiveKitAPIKey:    Env("LIVEKIT_API_KEY", ""),
		LiveKitAPISecret: Env("LIVEKIT_API_SECRET", ""),

		APNsKeyID:   Env("APNS_KEY_ID", ""),
		APNsTeamID:  Env("APNS_TEAM_ID", ""),
		APNsKeyPath: Env("APNS_KEY_PATH", ""),
		APNsTopic:   Env("APNS_TOPIC", ""),
		APNsEnv:     Env("APNS_ENV", "sandbox"),

		InternalSecret: Env("WAYPOINTS_INTERNAL_SECRET", ""),
		BenchSecret:    Env("WAYPOINTS_BENCH_SECRET", ""),
	}

	var errs []error
	var err error
	if c.MaxConns, err = EnvInt("WAYPOINTS_MAX_CONNS", 65536); err != nil {
		errs = append(errs, err)
	}
	switch c.Env {
	case "dev", "bench", "prod":
	default:
		errs = append(errs, fmt.Errorf("WAYPOINTS_ENV=%q: want dev, bench, or prod", c.Env))
	}
	// Fail closed on secrets: the bench key exists only in bench, and prod
	// must have the three values it cannot run safely without.
	if c.Env != "bench" {
		c.BenchSecret = ""
	}
	if c.Env == "prod" {
		for _, req := range []struct{ key, val string }{
			{"SUPABASE_URL", c.SupabaseURL},
			{"DATABASE_URL", c.DatabaseURL},
			{"WAYPOINTS_INTERNAL_SECRET", c.InternalSecret},
		} {
			if strings.TrimSpace(req.val) == "" {
				errs = append(errs, fmt.Errorf("%s is required when WAYPOINTS_ENV=prod", req.key))
			}
		}
	}
	if c.Env == "bench" {
		// Bench runs entirely in memory; a database or Supabase project here
		// means the environment was misconfigured.
		if c.DatabaseURL != "" || c.SupabaseURL != "" {
			errs = append(errs, errors.New("WAYPOINTS_ENV=bench requires DATABASE_URL and SUPABASE_URL to be unset"))
		}
	}
	if c.Env == "dev" || c.Env == "bench" {
		// A dev gateway must never write to a remote database.
		if host := dbHost(c.DatabaseURL); host != "" && !localDBHost(host) {
			errs = append(errs, fmt.Errorf("DATABASE_URL host %q is not loopback; dev and bench only use a local database", host))
		}
	}
	if err := c.LogLevel.UnmarshalText([]byte(Env("WAYPOINTS_LOG_LEVEL", "info"))); err != nil {
		errs = append(errs, fmt.Errorf("WAYPOINTS_LOG_LEVEL: %w", err))
	}
	defFormat := "json"
	if c.Env == "dev" {
		defFormat = "text"
	}
	c.LogFormat = Env("WAYPOINTS_LOG_FORMAT", defFormat)
	if c.LogFormat != "text" && c.LogFormat != "json" {
		errs = append(errs, fmt.Errorf("WAYPOINTS_LOG_FORMAT=%q: want text or json", c.LogFormat))
	}
	if c.ShutdownTimeout, err = EnvDuration("WAYPOINTS_SHUTDOWN_TIMEOUT", 5*time.Second); err != nil {
		errs = append(errs, err)
	}
	switch c.APNsEnv {
	case "sandbox", "production":
	default:
		errs = append(errs, fmt.Errorf("APNS_ENV=%q: want sandbox or production", c.APNsEnv))
	}
	return c, errors.Join(errs...)
}

// dbHost extracts the host from a Postgres connection string, in either the
// URL form (postgres://user:pass@host:port/db or postgresql://...) or the
// keyword form (host=... port=... dbname=...). It returns "" when no host can
// be found.
func dbHost(url string) string {
	url = strings.TrimSpace(url)
	if url == "" {
		return ""
	}
	if i := strings.Index(url, "://"); i >= 0 {
		authority := url[i+3:]
		if j := strings.IndexAny(authority, "/?"); j >= 0 {
			authority = authority[:j]
		}
		if at := strings.LastIndex(authority, "@"); at >= 0 {
			authority = authority[at+1:]
		}
		host := authority
		if strings.HasPrefix(host, "[") { // [::1]:5432
			if end := strings.Index(host, "]"); end >= 0 {
				return host[1:end]
			}
		}
		if colon := strings.LastIndex(host, ":"); colon >= 0 {
			host = host[:colon]
		}
		return strings.ToLower(host)
	}
	// keyword/value form: first host= wins, like libpq.
	for _, f := range strings.Fields(url) {
		if h, ok := strings.CutPrefix(f, "host="); ok {
			return strings.ToLower(strings.Trim(h, `'"`))
		}
	}
	return ""
}

// localDBHost reports whether host names this machine or the local Docker
// daemon. Anything else is a remote database dev and bench must not touch.
func localDBHost(host string) bool {
	switch host {
	case "localhost", "127.0.0.1", "::1", "0.0.0.0", "host.docker.internal":
		return true
	}
	return false
}

// Env returns the variable's value, or def when it is unset or empty.
func Env(key, def string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return def
}

// EnvInt parses an integer variable.
func EnvInt(key string, def int) (int, error) {
	v := Env(key, "")
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def, fmt.Errorf("%s=%q: %w", key, v, err)
	}
	return n, nil
}

// EnvBool parses a boolean variable (1, true, yes, on / 0, false, no, off).
func EnvBool(key string, def bool) (bool, error) {
	switch strings.ToLower(Env(key, "")) {
	case "":
		return def, nil
	case "1", "true", "yes", "on":
		return true, nil
	case "0", "false", "no", "off":
		return false, nil
	}
	return def, fmt.Errorf("%s=%q: want a boolean", key, os.Getenv(key))
}

// EnvDuration parses a Go duration variable such as "5s" or "100ms".
func EnvDuration(key string, def time.Duration) (time.Duration, error) {
	v := Env(key, "")
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def, fmt.Errorf("%s=%q: %w", key, v, err)
	}
	return d, nil
}

// loadDotEnv applies KEY=VALUE lines from a .env file. Blank lines and lines
// starting with # are skipped; an optional "export " prefix and surrounding
// single or double quotes on the value are stripped.
func loadDotEnv() error {
	path := os.Getenv("WAYPOINTS_ENV_FILE")
	explicit := path != ""
	if !explicit {
		path = ".env"
	}
	f, err := os.Open(path)
	if err != nil {
		if !explicit && errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("env file: %w", err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			return fmt.Errorf("%s:%d: want KEY=VALUE", path, n)
		}
		k, v = strings.TrimSpace(k), strings.TrimSpace(v)
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		if _, set := os.LookupEnv(k); !set {
			os.Setenv(k, v)
		}
	}
	return sc.Err()
}
