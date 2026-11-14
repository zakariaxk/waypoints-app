// Package api serves the gateway's JSON writes that need instant geographic
// fan-out or a push: reports and meets (section 6). Each handler writes
// Postgres, then publishes a MapEvent to every viewer whose viewport holds the
// point.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/push"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
	"waypoints/server/internal/ws"
)

// Service holds the handlers' dependencies.
type Service struct {
	store *store.Store
	auth  *auth.Verifier
	ws    *ws.Server
	push  *push.Service
	limit *Limiter
}

// Register mounts the report and meet endpoints.
func Register(a *app.App) {
	s := &Service{
		store: app.MustLookup[*store.Store](a),
		auth:  app.MustLookup[*auth.Verifier](a),
		ws:    app.MustLookup[*ws.Server](a),
		limit: NewLimiter(10, 10*time.Minute),
	}
	s.push, _ = app.Lookup[*push.Service](a)
	a.Mux.HandleFunc("POST /v1/reports", Authed(s.auth, s.postReport))
	a.Mux.HandleFunc("POST /v1/reports/{id}/vote", Authed(s.auth, s.voteReport))
	a.Mux.HandleFunc("DELETE /v1/reports/{id}", Authed(s.auth, s.undoReport))
	s.registerMeets(a) // meets.go
	app.Provide(a, s)
}

// MARK: shared HTTP helpers, used by convoy and voice too.

// Handler is an authenticated handler.
type Handler func(w http.ResponseWriter, r *http.Request, c auth.Claims)

// Authed verifies the bearer token before calling h.
func Authed(v *auth.Verifier, h Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := v.FromRequest(r)
		if errors.Is(err, auth.ErrSuspended) {
			Error(w, http.StatusForbidden, "suspended")
			return
		}
		if err != nil {
			Error(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		h(w, r, c)
	}
}

// Error writes {"error": msg}.
func Error(w http.ResponseWriter, code int, msg string) {
	JSON(w, code, map[string]string{"error": msg})
}

// JSON writes v with status code.
func JSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

// Decode reads a JSON body of at most 64 KB.
func Decode(r *http.Request, v any) error {
	return json.NewDecoder(http.MaxBytesReader(nil, r.Body, 64<<10)).Decode(v)
}

// Pool returns the pool or writes 503.
func Pool(w http.ResponseWriter, s *store.Store) *pgxpool.Pool {
	p := s.Pool()
	if p == nil {
		Error(w, http.StatusServiceUnavailable, "database unavailable")
	}
	return p
}

// Limiter is a per-key sliding window.
type Limiter struct {
	mu     sync.Mutex
	n      int
	window time.Duration
	hits   map[string][]time.Time
}

// NewLimiter allows n events per window per key.
func NewLimiter(n int, window time.Duration) *Limiter {
	return &Limiter{n: n, window: window, hits: map[string][]time.Time{}}
}

// Allow records an event for key and reports whether it is within the limit.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	h := l.hits[key][:0]
	for _, t := range l.hits[key] {
		if now.Sub(t) < l.window {
			h = append(h, t)
		}
	}
	if len(h) >= l.n {
		l.hits[key] = h
		return false
	}
	l.hits[key] = append(h, now)
	return true
}

// MARK: reports

var lifetimes = map[string]time.Duration{
	"police":     45 * time.Minute,
	"hazard":     2 * time.Hour,
	"closure":    24 * time.Hour,
	"pothole":    90 * 24 * time.Hour,
	"rough_road": 90 * 24 * time.Hour,
}

var permanentKinds = map[string]bool{"speed_bump": true, "steep_entrance": true, "fuel_e85": true}

type reportJSON struct {
	ID            string     `json:"id"`
	AuthorID      string     `json:"author_id"`
	Kind          string     `json:"kind"`
	Lat           float64    `json:"lat"`
	Lng           float64    `json:"lng"`
	Note          *string    `json:"note"`
	Confirmations int        `json:"confirmations"`
	ExpiresAt     *time.Time `json:"expires_at"`
	Permanent     bool       `json:"permanent"`
	CreatedAt     time.Time  `json:"created_at"`
}

const reportCols = `id::text, author_id::text, kind::text, st_y(geom::geometry), st_x(geom::geometry), note,
	confirmations, expires_at, permanent, created_at`

func scanReport(row pgx.Row) (reportJSON, error) {
	var r reportJSON
	err := row.Scan(&r.ID, &r.AuthorID, &r.Kind, &r.Lat, &r.Lng, &r.Note, &r.Confirmations, &r.ExpiresAt, &r.Permanent, &r.CreatedAt)
	return r, err
}

func (s *Service) publishReport(r reportJSON, op wire.MapEvent_Op) {
	s.ws.PublishMapEvent(&wire.MapEvent{Kind: wire.MapEvent_REPORT, Id: r.ID, Op: op,
		LatE7: geo.E7(r.Lat), LngE7: geo.E7(r.Lng), Subtype: r.Kind, Title: strings.ReplaceAll(r.Kind, "_", " ")})
}

func (s *Service) postReport(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var body struct {
		Kind string  `json:"kind"`
		Lat  float64 `json:"lat"`
		Lng  float64 `json:"lng"`
		Note *string `json:"note"`
	}
	if Decode(r, &body) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	_, temp := lifetimes[body.Kind]
	if !temp && !permanentKinds[body.Kind] {
		Error(w, http.StatusBadRequest, "kind")
		return
	}
	if !geo.Valid(geo.E7(body.Lat), geo.E7(body.Lng)) {
		Error(w, http.StatusBadRequest, "location")
		return
	}
	if body.Note != nil && len([]rune(*body.Note)) > 120 {
		Error(w, http.StatusBadRequest, "note")
		return
	}
	if !s.limit.Allow(c.UserID) {
		Error(w, http.StatusTooManyRequests, "rate limited")
		return
	}
	pool := Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	var expires *time.Time
	if d, ok := lifetimes[body.Kind]; ok {
		t := time.Now().Add(d)
		expires = &t
	}
	h3 := int64(geo.Cell(geo.E7(body.Lat), geo.E7(body.Lng), geo.ResCell))

	// Merge with a live report of the same kind within 30 m: that is a confirmation.
	var existing string
	err := pool.QueryRow(ctx, `select id::text from public.reports
		where kind = $1::public.report_kind and (permanent or expires_at > now())
		  and st_dwithin(geom, st_setsrid(st_makepoint($2, $3), 4326)::geography, 30)
		order by created_at desc limit 1`, body.Kind, body.Lng, body.Lat).Scan(&existing)
	var rep reportJSON
	switch {
	case err == nil:
		rep, err = s.confirm(ctx, pool, existing, c.UserID, body.Kind)
	case errors.Is(err, pgx.ErrNoRows):
		rep, err = scanReport(pool.QueryRow(ctx, `insert into public.reports
			(author_id, kind, geom, h3_r7, note, expires_at, permanent)
			values ($1, $2::public.report_kind, st_setsrid(st_makepoint($3, $4), 4326)::geography, $5, $6, $7, $8)
			returning `+reportCols, c.UserID, body.Kind, body.Lng, body.Lat, h3, body.Note, expires, expires == nil))
		if err == nil {
			_, err = pool.Exec(ctx, `insert into public.report_votes (report_id, user_id, still_there) values ($1, $2, true)
				on conflict do nothing`, rep.ID, c.UserID)
		}
	}
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not save report")
		return
	}
	s.publishReport(rep, wire.MapEvent_UPSERT)
	JSON(w, http.StatusCreated, rep)
}

func (s *Service) confirm(ctx context.Context, pool *pgxpool.Pool, id, userID, kind string) (reportJSON, error) {
	var ext any
	if d, ok := lifetimes[kind]; ok {
		ext = time.Now().Add(d)
	}
	_, err := pool.Exec(ctx, `insert into public.report_votes (report_id, user_id, still_there, created_at)
		values ($1, $2, true, now()) on conflict (report_id, user_id) do update set still_there = true, created_at = now()`, id, userID)
	if err != nil {
		return reportJSON{}, err
	}
	return scanReport(pool.QueryRow(ctx, `update public.reports set confirmations = confirmations + 1,
		expires_at = case when permanent then expires_at else greatest(expires_at, $2::timestamptz) end
		where id = $1 returning `+reportCols, id, ext))
}

func (s *Service) voteReport(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var body struct {
		StillThere bool `json:"still_there"`
	}
	if Decode(r, &body) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	pool := Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	id := r.PathValue("id")
	rep, err := scanReport(pool.QueryRow(ctx, `select `+reportCols+` from public.reports where id = $1`, id))
	if err != nil {
		Error(w, http.StatusNotFound, "not found")
		return
	}
	if body.StillThere {
		rep, err = s.confirm(ctx, pool, id, c.UserID, rep.Kind)
		if err != nil {
			Error(w, http.StatusInternalServerError, "could not vote")
			return
		}
		s.publishReport(rep, wire.MapEvent_UPSERT)
		JSON(w, http.StatusOK, rep)
		return
	}
	_, err = pool.Exec(ctx, `insert into public.report_votes (report_id, user_id, still_there, created_at)
		values ($1, $2, false, now()) on conflict (report_id, user_id) do update set still_there = false, created_at = now()`, id, c.UserID)
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not vote")
		return
	}
	// Two "Gone" votes with no later "Still there" remove the report (section 5.3).
	var gone int
	_ = pool.QueryRow(ctx, `select count(*) from public.report_votes v where v.report_id = $1 and not v.still_there
		and v.created_at > coalesce((select max(created_at) from public.report_votes where report_id = $1 and still_there),
		                            '-infinity'::timestamptz)`, id).Scan(&gone)
	if gone >= 2 {
		if _, err := pool.Exec(ctx, `delete from public.reports where id = $1`, id); err == nil {
			s.publishReport(rep, wire.MapEvent_REMOVE)
		}
	}
	JSON(w, http.StatusOK, rep)
}

// undoReport removes the author's own report within 5 minutes of posting (M5 "Undo").
func (s *Service) undoReport(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := Pool(w, s.store)
	if pool == nil {
		return
	}
	rep, err := scanReport(pool.QueryRow(r.Context(), `delete from public.reports
		where id = $1 and author_id = $2 and created_at > now() - interval '5 minutes' returning `+reportCols,
		r.PathValue("id"), c.UserID))
	if err != nil {
		Error(w, http.StatusNotFound, "not found")
		return
	}
	s.publishReport(rep, wire.MapEvent_REMOVE)
	w.WriteHeader(http.StatusNoContent)
}
