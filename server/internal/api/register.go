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
	a.Mux.HandleFunc("POST /v1/meets", Authed(s.auth, s.createMeet))
	a.Mux.HandleFunc("PATCH /v1/meets/{id}", Authed(s.auth, s.updateMeet))
	a.Mux.HandleFunc("DELETE /v1/meets/{id}", Authed(s.auth, s.cancelMeet))
	a.Go("meet-checkins", s.runCheckins)
	app.Provide(a, s)
}

// runCheckins records a check-in for every Going RSVP within 200 m of a meet while it is on.
// It reads positions only from this node's memory and writes no coordinates.
func (s *Service) runCheckins(ctx context.Context) {
	t := time.NewTicker(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		pool := s.store.Pool()
		if pool == nil {
			continue
		}
		rows, err := pool.Query(ctx, `select m.id::text, st_y(m.geom::geometry), st_x(m.geom::geometry), r.user_id::text
			from public.meets m join public.meet_rsvps r on r.meet_id = m.id
			where m.cancelled_at is null and m.starts_at <= now() and m.ends_at > now() and r.status = 'going'
			  and not exists (select 1 from public.meet_checkins c where c.meet_id = m.id and c.user_id = r.user_id)`)
		if err != nil {
			continue
		}
		type hit struct{ meet, user string }
		var hits []hit
		for rows.Next() {
			var meet, user string
			var lat, lng float64
			if rows.Scan(&meet, &lat, &lng, &user) != nil {
				continue
			}
			if la, ln, ok := s.ws.LastFix(user); ok && geo.DistanceM(la, ln, geo.E7(lat), geo.E7(lng)) <= 200 {
				hits = append(hits, hit{meet, user})
			}
		}
		rows.Close()
		for _, h := range hits {
			_, _ = pool.Exec(ctx, `insert into public.meet_checkins (meet_id, user_id) values ($1, $2) on conflict do nothing`, h.meet, h.user)
		}
	}
}

// MARK: shared HTTP helpers, used by convoy and voice too.

// Handler is an authenticated handler.
type Handler func(w http.ResponseWriter, r *http.Request, c auth.Claims)

// Authed verifies the bearer token before calling h.
func Authed(v *auth.Verifier, h Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		c, err := v.FromRequest(r)
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

// MARK: meets

type meetBody struct {
	Title      string    `json:"title"`
	Kind       string    `json:"kind"`
	Lat        float64   `json:"lat"`
	Lng        float64   `json:"lng"`
	PlaceName  string    `json:"place_name"`
	StartsAt   time.Time `json:"starts_at"`
	EndsAt     time.Time `json:"ends_at"`
	Details    string    `json:"details"`
	Visibility string    `json:"visibility"`
	TeamID     *string   `json:"team_id"`
}

func (b meetBody) validate() string {
	switch {
	case n(b.Title) < 1 || n(b.Title) > 50:
		return "title"
	case !map[string]bool{"meet": true, "cruise": true, "hangout": true, "track_day": true, "show": true}[b.Kind]:
		return "kind"
	case !geo.Valid(geo.E7(b.Lat), geo.E7(b.Lng)):
		return "location"
	case n(b.PlaceName) > 80, n(b.Details) > 500:
		return "text"
	case !b.EndsAt.After(b.StartsAt):
		return "ends_at"
	case !map[string]bool{"public": true, "friends": true, "team": true}[b.Visibility]:
		return "visibility"
	case (b.Visibility == "team") != (b.TeamID != nil):
		return "team_id"
	}
	return ""
}

func n(s string) int { return len([]rune(s)) }

type meetJSON struct {
	ID          string     `json:"id"`
	HostID      string     `json:"host_id"`
	Title       string     `json:"title"`
	Kind        string     `json:"kind"`
	Lat         float64    `json:"lat"`
	Lng         float64    `json:"lng"`
	PlaceName   string     `json:"place_name"`
	StartsAt    time.Time  `json:"starts_at"`
	EndsAt      time.Time  `json:"ends_at"`
	Details     string     `json:"details"`
	Visibility  string     `json:"visibility"`
	TeamID      *string    `json:"team_id"`
	CancelledAt *time.Time `json:"cancelled_at"`
	CreatedAt   time.Time  `json:"created_at"`
}

const meetCols = `id::text, host_id::text, title, kind::text, st_y(geom::geometry), st_x(geom::geometry),
	coalesce(place_name, ''), starts_at, ends_at, coalesce(details, ''), visibility::text, team_id::text, cancelled_at, created_at`

func scanMeet(row pgx.Row) (meetJSON, error) {
	var m meetJSON
	err := row.Scan(&m.ID, &m.HostID, &m.Title, &m.Kind, &m.Lat, &m.Lng, &m.PlaceName, &m.StartsAt, &m.EndsAt,
		&m.Details, &m.Visibility, &m.TeamID, &m.CancelledAt, &m.CreatedAt)
	return m, err
}

func (s *Service) publishMeet(m meetJSON, op wire.MapEvent_Op) {
	s.ws.PublishMapEvent(&wire.MapEvent{Kind: wire.MapEvent_MEET, Id: m.ID, Op: op,
		LatE7: geo.E7(m.Lat), LngE7: geo.E7(m.Lng), Subtype: m.Kind, Title: m.Title})
}

func (s *Service) canHostForTeam(ctx context.Context, pool *pgxpool.Pool, userID, teamID string) bool {
	var ok bool
	_ = pool.QueryRow(ctx, `select exists (
		select 1 from public.teams t where t.id = $2 and t.owner_id = $1
		union all
		select 1 from public.team_members m join public.team_roles r on r.id = m.role_id
		where m.team_id = $2 and m.user_id = $1 and (r.permissions & 32) <> 0)`, userID, teamID).Scan(&ok)
	return ok
}

func (s *Service) createMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b meetBody
	if Decode(r, &b) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if f := b.validate(); f != "" {
		Error(w, http.StatusBadRequest, f)
		return
	}
	pool := Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	if b.TeamID != nil && !s.canHostForTeam(ctx, pool, c.UserID, *b.TeamID) {
		Error(w, http.StatusForbidden, "forbidden")
		return
	}
	var today int
	_ = pool.QueryRow(ctx, `select count(*) from public.meets where host_id = $1 and created_at > now() - interval '1 day'`,
		c.UserID).Scan(&today)
	if today >= 3 {
		Error(w, http.StatusTooManyRequests, "daily meet limit")
		return
	}
	h3 := int64(geo.Cell(geo.E7(b.Lat), geo.E7(b.Lng), geo.ResCell))
	m, err := scanMeet(pool.QueryRow(ctx, `insert into public.meets
		(host_id, title, kind, geom, h3_r7, place_name, starts_at, ends_at, details, visibility, team_id)
		values ($1, $2, $3::public.meet_kind, st_setsrid(st_makepoint($4, $5), 4326)::geography, $6, $7, $8, $9, $10,
		        $11::public.meet_visibility, $12)
		returning `+meetCols, c.UserID, b.Title, b.Kind, b.Lng, b.Lat, h3, b.PlaceName, b.StartsAt, b.EndsAt, b.Details,
		b.Visibility, b.TeamID))
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not save meet")
		return
	}
	if b.Visibility == "public" {
		s.publishMeet(m, wire.MapEvent_UPSERT)
		if s.push != nil {
			go s.push.MeetNearby(context.WithoutCancel(ctx), c.UserID, m.ID, m.Title, geo.E7(m.Lat), geo.E7(m.Lng))
		}
	}
	JSON(w, http.StatusCreated, m)
}

func (s *Service) hostMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) (*pgxpool.Pool, meetJSON, bool) {
	pool := Pool(w, s.store)
	if pool == nil {
		return nil, meetJSON{}, false
	}
	m, err := scanMeet(pool.QueryRow(r.Context(), `select `+meetCols+` from public.meets where id = $1`, r.PathValue("id")))
	if err != nil {
		Error(w, http.StatusNotFound, "not found")
		return nil, m, false
	}
	if m.HostID != c.UserID {
		Error(w, http.StatusForbidden, "forbidden")
		return nil, m, false
	}
	return pool, m, true
}

func (s *Service) updateMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b meetBody
	if Decode(r, &b) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if f := b.validate(); f != "" {
		Error(w, http.StatusBadRequest, f)
		return
	}
	pool, old, ok := s.hostMeet(w, r, c)
	if !ok {
		return
	}
	ctx := r.Context()
	h3 := int64(geo.Cell(geo.E7(b.Lat), geo.E7(b.Lng), geo.ResCell))
	m, err := scanMeet(pool.QueryRow(ctx, `update public.meets set title = $2, kind = $3::public.meet_kind,
		geom = st_setsrid(st_makepoint($4, $5), 4326)::geography, h3_r7 = $6, place_name = $7, starts_at = $8, ends_at = $9,
		details = $10, visibility = $11::public.meet_visibility, team_id = $12
		where id = $1 returning `+meetCols, old.ID, b.Title, b.Kind, b.Lng, b.Lat, h3, b.PlaceName, b.StartsAt, b.EndsAt,
		b.Details, b.Visibility, b.TeamID))
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not save meet")
		return
	}
	if m.Visibility == "public" {
		s.publishMeet(m, wire.MapEvent_UPSERT)
	} else if old.Visibility == "public" {
		s.publishMeet(old, wire.MapEvent_REMOVE)
	}
	if s.push != nil && !m.StartsAt.Equal(old.StartsAt) {
		go s.push.MeetChanged(context.WithoutCancel(ctx), m.ID, m.Title, "New time: "+m.StartsAt.Format("Mon 3:04 PM"))
	}
	JSON(w, http.StatusOK, m)
}

func (s *Service) cancelMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool, m, ok := s.hostMeet(w, r, c)
	if !ok {
		return
	}
	ctx := r.Context()
	if _, err := pool.Exec(ctx, `update public.meets set cancelled_at = now() where id = $1`, m.ID); err != nil {
		Error(w, http.StatusInternalServerError, "could not cancel")
		return
	}
	s.publishMeet(m, wire.MapEvent_REMOVE)
	if s.push != nil {
		go s.push.MeetChanged(context.WithoutCancel(ctx), m.ID, m.Title, "Cancelled by the host.")
	}
	w.WriteHeader(http.StatusNoContent)
}
