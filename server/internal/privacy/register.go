// Package privacy resolves what each audience may see of a publisher
// (sections 2.5 and 7.4), caches privacy settings in memory, and serves
// PUT /v1/privacy, the only writer of privacy_settings.
//
// Settings are loaded from Postgres when a connection says Hello and kept in
// memory while the user has at least one connection. A PUT updates Postgres,
// then the cache, then publishes acl.<uid> on the bus so the user's live
// connections re-resolve within one tick.
package privacy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"sync"
	"time"

	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/bus"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
)

// Policy is the effective level per audience at one moment, after ghost mode
// and home zones are applied.
type Policy struct {
	Friends, Team, Nearby store.Level
}

// HiddenPolicy shows nothing to anyone.
var HiddenPolicy = Policy{store.Hidden, store.Hidden, store.Hidden}

// For returns the level for a viewer with the given relation.
func (p Policy) For(rel wire.Relation) store.Level {
	switch rel {
	case wire.Relation_FRIEND:
		return p.Friends
	case wire.Relation_TEAMMATE:
		return p.Team
	case wire.Relation_NEARBY:
		return p.Nearby
	}
	return store.Hidden
}

// AnyApprox reports whether some audience gets the approximate form.
func (p Policy) AnyApprox() bool {
	return p.Friends == store.Approx || p.Team == store.Approx || p.Nearby == store.Approx
}

// Effective applies the section 2.5 rules: ghost hides everything; inside a
// home zone every audience is capped at Approximate and Nearby is Hidden;
// Nearby is never Precise.
func Effective(s store.Settings, inHomeZone bool, now time.Time) Policy {
	if !s.GhostUntil.IsZero() && now.Before(s.GhostUntil) {
		return HiddenPolicy
	}
	p := Policy{Friends: s.Friends, Team: s.Team, Nearby: s.Nearby}
	if p.Nearby == store.Precise {
		p.Nearby = store.Approx
	}
	if inHomeZone {
		p.Friends = capApprox(p.Friends)
		p.Team = capApprox(p.Team)
		p.Nearby = store.Hidden
	}
	return p
}

func capApprox(l store.Level) store.Level {
	if l == store.Precise {
		return store.Approx
	}
	return l
}

// ACLSubject is the bus subject announcing that uid's settings changed.
func ACLSubject(uid uint64) string { return "acl." + strconv.FormatUint(uid, 10) }

type entry struct {
	s    store.Settings
	refs int
}

// Service is the settings cache and the HTTP handler.
type Service struct {
	store *store.Store
	bus   bus.Bus
	auth  *auth.Verifier

	mu    sync.RWMutex
	cache map[string]*entry
}

// Register provides *Service and mounts PUT /v1/privacy.
func Register(a *app.App) {
	s := &Service{
		store: app.MustLookup[*store.Store](a),
		bus:   bus.From(a),
		auth:  app.MustLookup[*auth.Verifier](a),
		cache: map[string]*entry{},
	}
	a.Mux.HandleFunc("PUT /v1/privacy", s.handlePut)
	app.Provide(a, s)
}

// Acquire loads the user's settings into the cache (from Postgres on first
// use) and pins them until Release.
func (s *Service) Acquire(ctx context.Context, userID string) (store.Settings, error) {
	s.mu.Lock()
	if e, ok := s.cache[userID]; ok {
		e.refs++
		st := e.s
		s.mu.Unlock()
		return st, nil
	}
	s.mu.Unlock()

	st, err := s.store.Settings(ctx, userID)
	if err != nil {
		return store.Settings{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if e, ok := s.cache[userID]; ok { // another connection raced us; its copy is as fresh
		e.refs++
		return e.s, nil
	}
	s.cache[userID] = &entry{s: st, refs: 1}
	return st, nil
}

// Release unpins a user's settings.
func (s *Service) Release(userID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if e, ok := s.cache[userID]; ok {
		if e.refs--; e.refs <= 0 {
			delete(s.cache, userID)
		}
	}
}

// Get returns cached settings; ok is false if the user has no connection here.
func (s *Service) Get(userID string) (store.Settings, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	e, ok := s.cache[userID]
	if !ok {
		return store.Settings{}, false
	}
	return e.s, true
}

type putBody struct {
	FriendsLevel      *store.Level    `json:"friends_level"`
	TeamLevel         *store.Level    `json:"team_level"`
	NearbyLevel       *store.Level    `json:"nearby_level"`
	GhostUntil        json.RawMessage `json:"ghost_until"` // absent: keep; null: clear; RFC 3339: set
	NotifyMeetsNearby *bool           `json:"notify_meets_nearby"`
	NotifyRadiusKm    *int            `json:"notify_radius_km"`
}

type settingsJSON struct {
	FriendsLevel      store.Level `json:"friends_level"`
	TeamLevel         store.Level `json:"team_level"`
	NearbyLevel       store.Level `json:"nearby_level"`
	GhostUntil        *time.Time  `json:"ghost_until"`
	NotifyMeetsNearby bool        `json:"notify_meets_nearby"`
	NotifyRadiusKm    int         `json:"notify_radius_km"`
}

func httpError(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

// handlePut merges the body into the current settings. Omitted fields keep
// their value, so a client may send only what changed.
func (s *Service) handlePut(w http.ResponseWriter, r *http.Request) {
	claims, err := s.auth.FromRequest(r)
	if err != nil {
		httpError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var b putBody
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		httpError(w, http.StatusBadRequest, "malformed body")
		return
	}
	ctx := r.Context()
	prof, err := s.store.Profile(ctx, claims.UserID)
	if errors.Is(err, store.ErrNotFound) {
		httpError(w, http.StatusNotFound, "no profile")
		return
	} else if err != nil {
		httpError(w, http.StatusServiceUnavailable, "store unavailable")
		return
	}
	cur, ok := s.Get(claims.UserID)
	if !ok {
		if cur, err = s.store.Settings(ctx, claims.UserID); err != nil {
			httpError(w, http.StatusServiceUnavailable, "store unavailable")
			return
		}
	}
	next := cur
	if b.FriendsLevel != nil {
		next.Friends = *b.FriendsLevel
	}
	if b.TeamLevel != nil {
		next.Team = *b.TeamLevel
	}
	if b.NearbyLevel != nil {
		next.Nearby = *b.NearbyLevel
	}
	if b.NotifyMeetsNearby != nil {
		next.NotifyMeetsNearby = *b.NotifyMeetsNearby
	}
	if b.NotifyRadiusKm != nil {
		next.NotifyRadiusKm = *b.NotifyRadiusKm
	}
	if len(b.GhostUntil) > 0 {
		if bytes.Equal(b.GhostUntil, []byte("null")) {
			next.GhostUntil = time.Time{}
		} else {
			var t time.Time
			if err := json.Unmarshal(b.GhostUntil, &t); err != nil {
				httpError(w, http.StatusBadRequest, "ghost_until must be RFC 3339 or null")
				return
			}
			next.GhostUntil = t
		}
	}
	if err := next.Validate(); err != nil {
		httpError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := s.store.PutSettings(ctx, claims.UserID, next); err != nil {
		httpError(w, http.StatusServiceUnavailable, "store unavailable")
		return
	}

	s.mu.Lock()
	if e, ok := s.cache[claims.UserID]; ok {
		e.s = next
	}
	s.mu.Unlock()
	payload, _ := json.Marshal(toJSON(next))
	_ = s.bus.Publish(ACLSubject(prof.UID), payload)

	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(payload)
}

func toJSON(st store.Settings) settingsJSON {
	out := settingsJSON{FriendsLevel: st.Friends, TeamLevel: st.Team, NearbyLevel: st.Nearby,
		NotifyMeetsNearby: st.NotifyMeetsNearby, NotifyRadiusKm: st.NotifyRadiusKm}
	if !st.GhostUntil.IsZero() {
		g := st.GhostUntil.UTC()
		out.GhostUntil = &g
	}
	return out
}

// Apply handles an acl.<uid> message for a user with a connection on this
// node: the payload carries the new settings (so other nodes need no database
// read), which replace the cached copy. It returns the current settings.
func (s *Service) Apply(userID string, payload []byte) (store.Settings, bool) {
	var j settingsJSON
	if len(payload) > 0 && json.Unmarshal(payload, &j) == nil {
		st := store.Settings{Friends: j.FriendsLevel, Team: j.TeamLevel, Nearby: j.NearbyLevel,
			NotifyMeetsNearby: j.NotifyMeetsNearby, NotifyRadiusKm: j.NotifyRadiusKm}
		if j.GhostUntil != nil {
			st.GhostUntil = *j.GhostUntil
		}
		if st.Validate() == nil {
			s.mu.Lock()
			if e, ok := s.cache[userID]; ok {
				e.s = st
			}
			s.mu.Unlock()
		}
	}
	return s.Get(userID)
}
