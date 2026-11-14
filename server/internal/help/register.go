// Package help serves help requests (PRD HELP-1..7): a driver who is stuck shares an exact spot
// with their friends and teammates, and optionally with drivers nearby without a name.
//
// Delivery: a MapEvent of kind HELP goes on the reliable lane to the requester's friends and
// teammates (and the requester's own devices) through the bus subject "help.deliver", which
// every node handles by enqueueing on its local connections of those uids. Only the opt-in
// nearby form goes to viewers of the point, through ws.PublishMapEvent, with no name. Friends
// and teammates within 25 km also get a push. Clients treat the event as a cue to reload
// GET /v1/help, which resolves names per viewer.
//
// Home zones do not apply: the requester chose to share the spot (HELP-7).
package help

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/proto"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/bus"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/push"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
	"waypoints/server/internal/ws"
)

const (
	// Lifetime is how long a request lasts without an extension (HELP-6).
	Lifetime = 60 * time.Minute
	// NotifyRadiusM bounds the push to friends and teammates (HELP-4).
	NotifyRadiusM  = 25_000
	deliverSubject = "help.deliver"
	// Neither kind has a notification_prefs column, so both are always delivered. They are
	// also the Activity kinds (notifications.kind).
	requestKind  push.Kind = "help_request"
	responseKind push.Kind = "help_response"
)

var kinds = map[string]string{
	"flat_tire":   "Flat tire",
	"jump_start":  "Jump start",
	"out_of_fuel": "Out of fuel",
	"stuck":       "Stuck",
	"other":       "Needs a hand",
}

// Service holds the handlers' dependencies.
type Service struct {
	store *store.Store
	ws    *ws.Server
	bus   bus.Bus
	push  *push.Service
	limit *api.Limiter
}

// Register mounts the help endpoints and the expiry sweep.
func Register(a *app.App) {
	s := &Service{
		store: app.MustLookup[*store.Store](a),
		ws:    app.MustLookup[*ws.Server](a),
		bus:   bus.From(a),
		limit: api.NewLimiter(6, time.Hour),
	}
	s.push, _ = app.Lookup[*push.Service](a)
	v := app.MustLookup[*auth.Verifier](a)
	_, _ = s.bus.Subscribe(deliverSubject, func(m bus.Msg) { s.onDeliver(m.Data) })
	a.Mux.HandleFunc("GET /v1/help", api.Authed(v, s.list))
	a.Mux.HandleFunc("GET /v1/help/{id}", api.Authed(v, s.get))
	a.Mux.HandleFunc("POST /v1/help", api.Authed(v, s.create))
	a.Mux.HandleFunc("POST /v1/help/{id}/respond", api.Authed(v, s.respond))
	a.Mux.HandleFunc("DELETE /v1/help/{id}", api.Authed(v, s.end))
	a.Mux.HandleFunc("PUT /v1/help/{id}/extend", api.Authed(v, s.extend))
	a.Go("help-expiry", s.runExpiry)
	app.Provide(a, s)
}

// MARK: rows

type responderJSON struct {
	UserID      string `json:"user_id"`
	DisplayName string `json:"display_name"`
}

type requestJSON struct {
	ID          string          `json:"id"`
	RequesterID *string         `json:"requester_id"` // null in the anonymous nearby form
	Kind        string          `json:"kind"`
	Lat         float64         `json:"lat"`
	Lng         float64         `json:"lng"`
	Note        *string         `json:"note"`
	ShowNearby  bool            `json:"show_nearby"`
	DisplayName *string         `json:"display_name"`
	CarLabel    *string         `json:"car_label"`
	ExpiresAt   time.Time       `json:"expires_at"`
	CreatedAt   time.Time       `json:"created_at"`
	Mine        bool            `json:"mine"`
	Coming      bool            `json:"coming"` // the viewer tapped "On my way"
	Responders  []responderJSON `json:"responders"`
	Count       int             `json:"responder_count"`

	requester string
	known     bool
}

const cols = `h.id::text, h.requester_id::text, h.kind::text, st_y(h.geom::geometry), st_x(h.geom::geometry), h.note,
	h.show_nearby, h.expires_at, h.created_at`

func scan(row pgx.Row) (requestJSON, error) {
	var r requestJSON
	err := row.Scan(&r.ID, &r.requester, &r.Kind, &r.Lat, &r.Lng, &r.Note, &r.ShowNearby, &r.ExpiresAt, &r.CreatedAt)
	return r, err
}

// knownSQL is true when $1 (the viewer) is a friend or teammate of h.requester_id.
const knownSQL = `(exists (select 1 from public.friendships f where f.status = 'accepted'
		and least(f.requester_id, f.addressee_id) = least(h.requester_id, $1::uuid)
		and greatest(f.requester_id, f.addressee_id) = greatest(h.requester_id, $1::uuid))
	or exists (select 1 from public.team_members a join public.team_members b on b.team_id = a.team_id
		where a.user_id = h.requester_id and b.user_id = $1::uuid))`

const notBlockedSQL = `not exists (select 1 from public.blocks b where (b.blocker_id = h.requester_id and b.blocked_id = $1::uuid)
		or (b.blocker_id = $1::uuid and b.blocked_id = h.requester_id))`

// dress fills the viewer-specific fields: name and car for the requester and friends or
// teammates, nothing identifying for the nearby form.
func (s *Service) dress(ctx context.Context, pool *pgxpool.Pool, r *requestJSON, viewer string) {
	r.Mine = r.requester == viewer
	if r.Mine || r.known {
		id := r.requester
		r.RequesterID = &id
		if p, err := s.store.Profile(ctx, r.requester); err == nil {
			name, car := p.DisplayName, p.CarLabel
			r.DisplayName = &name
			if car != "" {
				r.CarLabel = &car
			}
		}
	}
	r.Responders = []responderJSON{}
	rows, err := pool.Query(ctx, `select x.user_id::text, coalesce(p.display_name, '') from public.help_responses x
		left join public.profiles p on p.user_id = x.user_id where x.request_id = $1 order by x.created_at`, r.ID)
	if err != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var x responderJSON
		if rows.Scan(&x.UserID, &x.DisplayName) != nil {
			continue
		}
		r.Count++
		if x.UserID == viewer {
			r.Coming = true
		}
		// The requester is told who is coming (HELP-5); others see only the count.
		if r.Mine {
			r.Responders = append(r.Responders, x)
		}
	}
}

// MARK: delivery

type envelope struct {
	UIDs  []uint64 `json:"uids"`
	Frame []byte   `json:"frame"`
}

func (s *Service) onDeliver(data []byte) {
	var e envelope
	if json.Unmarshal(data, &e) != nil {
		return
	}
	var f wire.ServerFrame
	if len(e.Frame) == 0 || proto.Unmarshal(e.Frame, &f) != nil {
		return
	}
	for _, uid := range e.UIDs {
		s.ws.SendToUID(uid, &f)
	}
}

// publish sends the event to the requester, their friends and teammates, and, for the nearby
// form, to viewers of the point.
func (s *Service) publish(ctx context.Context, r requestJSON, op wire.MapEvent_Op) {
	title := ""
	if p, err := s.store.Profile(ctx, r.requester); err == nil {
		title = p.DisplayName
		if p.CarLabel != "" {
			title += " · " + p.CarLabel
		}
		uids := []uint64{p.UID}
		if rel, err := s.store.Relations(ctx, r.requester); err == nil {
			uids = append(uids, rel.Friends...)
			uids = append(uids, rel.Teammates...)
		}
		ev := &wire.MapEvent{Kind: wire.MapEvent_HELP, Id: r.ID, Op: op, LatE7: geo.E7(r.Lat), LngE7: geo.E7(r.Lng),
			Subtype: r.Kind, Title: title}
		if frame, err := proto.Marshal(&wire.ServerFrame{Body: &wire.ServerFrame_MapEvent{MapEvent: ev}}); err == nil {
			if b, err := json.Marshal(envelope{UIDs: uids, Frame: frame}); err == nil {
				_ = s.bus.Publish(deliverSubject, b)
			}
		}
	}
	if r.ShowNearby {
		s.ws.PublishMapEvent(&wire.MapEvent{Kind: wire.MapEvent_HELP, Id: r.ID, Op: op,
			LatE7: geo.E7(r.Lat), LngE7: geo.E7(r.Lng), Subtype: r.Kind})
	}
}

// notifyNearby pushes to friends and teammates whose presence cell is within 25 km (HELP-4).
func (s *Service) notifyNearby(ctx context.Context, r requestJSON) {
	pool := s.store.Pool()
	if pool == nil || s.push == nil {
		return
	}
	rows, err := pool.Query(ctx, `select c.user_id::text, c.h3_r7 from public.user_presence_cell c
		where c.user_id <> $1::uuid
		  and (exists (select 1 from public.friendships f where f.status = 'accepted'
		         and least(f.requester_id, f.addressee_id) = least(c.user_id, $1::uuid)
		         and greatest(f.requester_id, f.addressee_id) = greatest(c.user_id, $1::uuid))
		       or exists (select 1 from public.team_members a join public.team_members b on b.team_id = a.team_id
		         where a.user_id = $1::uuid and b.user_id = c.user_id))
		  and not exists (select 1 from public.blocks b where (b.blocker_id = c.user_id and b.blocked_id = $1::uuid)
		         or (b.blocker_id = $1::uuid and b.blocked_id = c.user_id))`, r.requester)
	if err != nil {
		return
	}
	lat, lng := geo.E7(r.Lat), geo.E7(r.Lng)
	var ids []string
	for rows.Next() {
		var id string
		var cell int64
		if rows.Scan(&id, &cell) != nil {
			continue
		}
		clat, clng := geo.Centre(uint64(cell))
		if geo.DistanceM(clat, clng, lat, lng) <= NotifyRadiusM {
			ids = append(ids, id)
		}
	}
	rows.Close()
	name := "A friend"
	if p, err := s.store.Profile(ctx, r.requester); err == nil && p.DisplayName != "" {
		name = p.DisplayName
	}
	s.push.Send(ctx, ids, push.Note{Kind: requestKind, Title: name + " needs a hand",
		Body: kinds[r.Kind] + ". Tap to see where.", URL: "waypoints://help/" + r.ID,
		ActorID: r.requester, Dedupe: "help:" + r.ID})
}

// MARK: handlers

func (s *Service) list(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	q := r.URL.Query()
	f := func(k string) (float64, bool) {
		v, err := strconv.ParseFloat(q.Get(k), 64)
		return v, err == nil && !math.IsNaN(v)
	}
	minLat, ok1 := f("min_lat")
	minLng, ok2 := f("min_lng")
	maxLat, ok3 := f("max_lat")
	maxLng, ok4 := f("max_lng")
	if !ok1 || !ok2 || !ok3 || !ok4 {
		api.Error(w, http.StatusBadRequest, "bbox")
		return
	}
	ctx := r.Context()
	rows, err := pool.Query(ctx, `select `+cols+`, `+knownSQL+` from public.help_requests h
		where h.ended_at is null and h.expires_at > now()
		  and (h.requester_id = $1::uuid or (`+notBlockedSQL+`
		       and st_intersects(h.geom, st_makeenvelope($2, $3, $4, $5, 4326)::geography)
		       and (h.show_nearby or `+knownSQL+`)))
		order by h.created_at desc limit 100`, c.UserID, minLng, minLat, maxLng, maxLat)
	if err != nil {
		api.Error(w, http.StatusInternalServerError, "could not load")
		return
	}
	var out []requestJSON
	for rows.Next() {
		var x requestJSON
		if rows.Scan(&x.ID, &x.requester, &x.Kind, &x.Lat, &x.Lng, &x.Note, &x.ShowNearby, &x.ExpiresAt, &x.CreatedAt,
			&x.known) == nil {
			out = append(out, x)
		}
	}
	rows.Close()
	for i := range out {
		s.dress(ctx, pool, &out[i], c.UserID)
	}
	if out == nil {
		out = []requestJSON{}
	}
	api.JSON(w, http.StatusOK, out)
}

// load returns an active request the viewer may see.
func (s *Service) load(ctx context.Context, pool *pgxpool.Pool, id, viewer string) (requestJSON, error) {
	var x requestJSON
	err := pool.QueryRow(ctx, `select `+cols+`, `+knownSQL+` from public.help_requests h
		where h.id = $2::uuid and h.ended_at is null and h.expires_at > now()
		  and (h.requester_id = $1::uuid or (`+notBlockedSQL+` and (h.show_nearby or `+knownSQL+`)))`, viewer, id).
		Scan(&x.ID, &x.requester, &x.Kind, &x.Lat, &x.Lng, &x.Note, &x.ShowNearby, &x.ExpiresAt, &x.CreatedAt, &x.known)
	return x, err
}

func (s *Service) get(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	x, err := s.load(r.Context(), pool, r.PathValue("id"), c.UserID)
	if err != nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	s.dress(r.Context(), pool, &x, c.UserID)
	api.JSON(w, http.StatusOK, x)
}

func (s *Service) create(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b struct {
		Kind       string  `json:"kind"`
		Lat        float64 `json:"lat"`
		Lng        float64 `json:"lng"`
		Note       *string `json:"note"`
		ShowNearby bool    `json:"show_nearby"`
	}
	if api.Decode(r, &b) != nil {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if _, ok := kinds[b.Kind]; !ok {
		api.Error(w, http.StatusBadRequest, "kind")
		return
	}
	if !geo.Valid(geo.E7(b.Lat), geo.E7(b.Lng)) {
		api.Error(w, http.StatusBadRequest, "location")
		return
	}
	if b.Note != nil {
		t := strings.TrimSpace(*b.Note)
		if len([]rune(t)) > 120 {
			api.Error(w, http.StatusBadRequest, "note")
			return
		}
		if t == "" {
			b.Note = nil
		} else {
			b.Note = &t
		}
	}
	if !s.limit.Allow(c.UserID) {
		api.Error(w, http.StatusTooManyRequests, "rate limited")
		return
	}
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	// A request past its hour is ended here too, so it never blocks a new one.
	s.expire(ctx, pool, `and requester_id = $1::uuid`, c.UserID)
	h3 := int64(geo.Cell(geo.E7(b.Lat), geo.E7(b.Lng), geo.ResCell))
	x, err := scan(pool.QueryRow(ctx, `insert into public.help_requests as h
		(requester_id, kind, geom, h3_r7, note, show_nearby, expires_at)
		values ($1, $2::public.help_kind, st_setsrid(st_makepoint($3, $4), 4326)::geography, $5, $6, $7, $8)
		returning `+cols, c.UserID, b.Kind, b.Lng, b.Lat, h3, b.Note, b.ShowNearby, time.Now().Add(Lifetime)))
	if err != nil {
		var pg *pgconn.PgError
		if errors.As(err, &pg) && pg.Code == "23505" {
			api.Error(w, http.StatusConflict, "already active")
			return
		}
		api.Error(w, http.StatusInternalServerError, "could not save")
		return
	}
	bg := context.WithoutCancel(ctx)
	go s.publish(bg, x, wire.MapEvent_UPSERT)
	go s.notifyNearby(bg, x)
	s.dress(ctx, pool, &x, c.UserID)
	api.JSON(w, http.StatusCreated, x)
}

func (s *Service) respond(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	x, err := s.load(ctx, pool, r.PathValue("id"), c.UserID)
	if err != nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	if x.requester == c.UserID {
		api.Error(w, http.StatusBadRequest, "own request")
		return
	}
	tag, err := pool.Exec(ctx, `insert into public.help_responses (request_id, user_id) values ($1, $2) on conflict do nothing`,
		x.ID, c.UserID)
	if err != nil {
		api.Error(w, http.StatusInternalServerError, "could not save")
		return
	}
	if tag.RowsAffected() > 0 {
		bg := context.WithoutCancel(ctx)
		go s.publish(bg, x, wire.MapEvent_UPSERT)
		if s.push != nil {
			name := "A driver"
			if p, err := s.store.Profile(ctx, c.UserID); err == nil && p.DisplayName != "" {
				name = p.DisplayName
			}
			go s.push.Send(bg, []string{x.requester}, push.Note{Kind: responseKind, Title: name + " is on the way",
				Body: "Tap to see your request.", URL: "waypoints://help/" + x.ID,
				ActorID: c.UserID, Dedupe: "help_response:" + x.ID + ":" + c.UserID,
				// The help_responses trigger (migration W8-1E) wrote the Activity row.
				Recorded: true})
		}
	}
	s.dress(ctx, pool, &x, c.UserID)
	api.JSON(w, http.StatusOK, x)
}

func (s *Service) end(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	x, err := scan(pool.QueryRow(r.Context(), `update public.help_requests h set ended_at = now()
		where h.id = $1::uuid and h.requester_id = $2::uuid and h.ended_at is null returning `+cols,
		r.PathValue("id"), c.UserID))
	if err != nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	go s.publish(context.WithoutCancel(r.Context()), x, wire.MapEvent_REMOVE)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) extend(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	x, err := scan(pool.QueryRow(ctx, `update public.help_requests h set expires_at = $3
		where h.id = $1::uuid and h.requester_id = $2::uuid and h.ended_at is null and h.expires_at > now()
		returning `+cols, r.PathValue("id"), c.UserID, time.Now().Add(Lifetime)))
	if err != nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	s.dress(ctx, pool, &x, c.UserID)
	api.JSON(w, http.StatusOK, x)
}

// MARK: expiry

// expire ends requests past their hour and publishes REMOVE for each. The update is atomic,
// so with several nodes sweeping each row is announced once.
func (s *Service) expire(ctx context.Context, pool *pgxpool.Pool, where string, args ...any) {
	rows, err := pool.Query(ctx, `update public.help_requests h set ended_at = now()
		where h.ended_at is null and h.expires_at <= now() `+where+` returning `+cols, args...)
	if err != nil {
		return
	}
	var ended []requestJSON
	for rows.Next() {
		if x, err := scan(rows); err == nil {
			ended = append(ended, x)
		}
	}
	rows.Close()
	for _, x := range ended {
		s.publish(context.WithoutCancel(ctx), x, wire.MapEvent_REMOVE)
	}
}

func (s *Service) runExpiry(ctx context.Context) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		if pool := s.store.Pool(); pool != nil {
			s.expire(ctx, pool, "")
		}
	}
}
