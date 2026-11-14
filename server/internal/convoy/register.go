// Package convoy keeps convoy state in memory on the node that created it,
// mirrors it to Postgres (table convoys) on every change so any node can load
// it, and serves the convoy endpoints of section 6. Members receive each
// other's precise positions through package ws while they are members.
package convoy

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/push"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
	"waypoints/server/internal/ws"
)

type place struct {
	Lat  float64 `json:"lat"`
	Lng  float64 `json:"lng"`
	Name string  `json:"name"`
}

type regroup struct {
	Lat   float64   `json:"lat"`
	Lng   float64   `json:"lng"`
	SetAt time.Time `json:"set_at"`
}

// Convoy is one convoy's state.
type Convoy struct {
	ID          string   `json:"id"`
	JoinCode    string   `json:"join_code"`
	Name        string   `json:"name"`
	LeaderID    string   `json:"leader_id"`
	LeaderUID   uint64   `json:"leader_uid"`
	MemberUIDs  []uint64 `json:"member_uids"`
	Destination *place   `json:"destination,omitempty"`
	Polyline    string   `json:"route_polyline"`
	Regroup     *regroup `json:"regroup,omitempty"`
	Ended       bool     `json:"ended"`
}

func (c *Convoy) has(uid uint64) bool {
	for _, m := range c.MemberUIDs {
		if m == uid {
			return true
		}
	}
	return false
}

func (c *Convoy) wire() *wire.ConvoyState {
	st := &wire.ConvoyState{ConvoyId: c.ID, LeaderUid: c.LeaderUID, MemberUids: append([]uint64(nil), c.MemberUIDs...),
		RoutePolyline: []byte(c.Polyline), Ended: c.Ended}
	if d := c.Destination; d != nil {
		st.Destination = &wire.Destination{LatE7: geo.E7(d.Lat), LngE7: geo.E7(d.Lng), Name: d.Name}
	}
	if r := c.Regroup; r != nil {
		st.Regroup = &wire.Regroup{LatE7: geo.E7(r.Lat), LngE7: geo.E7(r.Lng), SetMs: uint64(r.SetAt.UnixMilli())}
	}
	return st
}

// Service is the convoy registry.
type Service struct {
	store *store.Store
	ws    *ws.Server
	push  *push.Service

	mu     sync.Mutex
	byID   map[string]*Convoy
	byCode map[string]string
	voice  VoiceRooms
}

// VoiceRooms is implemented by package voice: every convoy has a LiveKit room
// (CNV-11) that a leaving member is removed from and that closes with the convoy.
type VoiceRooms interface {
	ConvoyLeft(convoyID string, uid uint64)
	ConvoyEnded(convoyID string)
}

// SetVoice installs the convoy room closer.
func (s *Service) SetVoice(v VoiceRooms) {
	s.mu.Lock()
	s.voice = v
	s.mu.Unlock()
}

// Register mounts the convoy endpoints and installs the membership authority.
func Register(a *app.App) {
	s := &Service{
		store:  app.MustLookup[*store.Store](a),
		ws:     app.MustLookup[*ws.Server](a),
		byID:   map[string]*Convoy{},
		byCode: map[string]string{},
	}
	s.push, _ = app.Lookup[*push.Service](a)
	v := app.MustLookup[*auth.Verifier](a)
	s.ws.SetConvoys(s)
	a.Mux.HandleFunc("POST /v1/convoys", api.Authed(v, s.create))
	a.Mux.HandleFunc("POST /v1/convoys/join", api.Authed(v, s.join))
	a.Mux.HandleFunc("PUT /v1/convoys/{id}/destination", api.Authed(v, s.setDestination))
	a.Mux.HandleFunc("PUT /v1/convoys/{id}/regroup", api.Authed(v, s.setRegroup))
	a.Mux.HandleFunc("DELETE /v1/convoys/{id}", api.Authed(v, s.end))
	a.Mux.HandleFunc("POST /v1/convoys/{id}/invite", api.Authed(v, s.invite))
	app.Provide(a, s)
}

// IsMember implements ws.ConvoyAuthority.
func (s *Service) IsMember(id string, uid uint64) bool {
	c := s.get(context.Background(), id)
	return c != nil && !c.Ended && c.has(uid)
}

// Snapshot implements ws.ConvoyAuthority.
func (s *Service) Snapshot(id string) *wire.ConvoyState {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.byID[id]; c != nil {
		return c.wire()
	}
	return nil
}

// Leave implements ws.ConvoyAuthority: a member leaving stops receiving
// positions immediately; the leader leaving hands over to the next member.
func (s *Service) Leave(id string, uid uint64) {
	s.mu.Lock()
	c := s.byID[id]
	if c == nil || !c.has(uid) {
		s.mu.Unlock()
		return
	}
	out := c.MemberUIDs[:0]
	for _, m := range c.MemberUIDs {
		if m != uid {
			out = append(out, m)
		}
	}
	c.MemberUIDs = out
	if len(out) == 0 {
		c.Ended = true
	} else if c.LeaderUID == uid {
		c.LeaderUID = out[0]
		c.LeaderID = ""
	}
	v := s.voice
	s.mu.Unlock()
	s.changed(context.Background(), c)
	if v != nil {
		go v.ConvoyLeft(id, uid)
	}
}

func (s *Service) get(ctx context.Context, id string) *Convoy {
	s.mu.Lock()
	c := s.byID[id]
	s.mu.Unlock()
	if c != nil {
		return c
	}
	return s.load(ctx, "id = $1", id)
}

func (s *Service) load(ctx context.Context, where, arg string) *Convoy {
	pool := s.store.Pool()
	if pool == nil {
		return nil
	}
	var raw []byte
	if pool.QueryRow(ctx, `select state from public.convoys where `+where+` and not ended`, arg).Scan(&raw) != nil {
		return nil
	}
	var c Convoy
	if json.Unmarshal(raw, &c) != nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing := s.byID[c.ID]; existing != nil {
		return existing
	}
	s.byID[c.ID] = &c
	s.byCode[c.JoinCode] = c.ID
	return &c
}

// changed mirrors to Postgres and sends ConvoyState to every member.
func (s *Service) changed(ctx context.Context, c *Convoy) {
	s.mu.Lock()
	raw, _ := json.Marshal(c)
	st := c.wire()
	members := append([]uint64(nil), c.MemberUIDs...)
	v := s.voice
	if c.Ended {
		delete(s.byID, c.ID)
		delete(s.byCode, c.JoinCode)
	}
	s.mu.Unlock()
	if c.Ended && v != nil {
		go v.ConvoyEnded(c.ID)
	}
	if pool := s.store.Pool(); pool != nil {
		_, _ = pool.Exec(ctx, `insert into public.convoys (id, join_code, state, ended, updated_at)
			values ($1, $2, $3, $4, now())
			on conflict (id) do update set state = excluded.state, ended = excluded.ended, updated_at = now()`,
			c.ID, c.JoinCode, raw, c.Ended)
	}
	frame := &wire.ServerFrame{Body: &wire.ServerFrame_Convoy{Convoy: st}}
	for _, m := range members {
		s.ws.SendToUID(m, frame)
		if c.Ended {
			s.ws.DropFromConvoy(c.ID, m)
		}
	}
}

// maxPolyline caps a convoy route: a saved road is at most a few thousand points.
const maxPolyline = 64 << 10

const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func randomCode(n int) string {
	var b strings.Builder
	for range n {
		i, _ := rand.Int(rand.Reader, big.NewInt(int64(len(codeAlphabet))))
		b.WriteByte(codeAlphabet[i.Int64()])
	}
	return b.String()
}

func (s *Service) uid(ctx context.Context, userID string) (uint64, error) {
	p, err := s.store.Profile(ctx, userID)
	if err != nil {
		return 0, err
	}
	return p.UID, nil
}

func (s *Service) create(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	var b struct {
		Name        string `json:"name"`
		Destination *place `json:"destination"`
		// Encoded polyline (precision 5) the convoy drives, e.g. a cruise's saved road (MEET-13).
		Polyline string `json:"route_polyline"`
	}
	if api.Decode(r, &b) != nil || len([]rune(b.Name)) > 40 || len(b.Polyline) > maxPolyline {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	uid, err := s.uid(r.Context(), cl.UserID)
	if err != nil {
		api.Error(w, http.StatusUnauthorized, "no profile")
		return
	}
	c := &Convoy{ID: randomCode(12), JoinCode: randomCode(6), Name: b.Name, LeaderID: cl.UserID, LeaderUID: uid,
		MemberUIDs: []uint64{uid}, Destination: b.Destination, Polyline: b.Polyline}
	s.mu.Lock()
	s.byID[c.ID] = c
	s.byCode[c.JoinCode] = c.ID
	s.mu.Unlock()
	s.changed(r.Context(), c)
	api.JSON(w, http.StatusCreated, map[string]string{"id": c.ID, "join_code": c.JoinCode})
}

func (s *Service) join(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	var b struct {
		JoinCode string `json:"join_code"`
	}
	if api.Decode(r, &b) != nil {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	code := strings.ToUpper(strings.TrimSpace(b.JoinCode))
	s.mu.Lock()
	id := s.byCode[code]
	c := s.byID[id]
	s.mu.Unlock()
	if c == nil {
		c = s.load(r.Context(), "join_code = $1", code)
	}
	if c == nil || c.Ended {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	uid, err := s.uid(r.Context(), cl.UserID)
	if err != nil {
		api.Error(w, http.StatusUnauthorized, "no profile")
		return
	}
	s.mu.Lock()
	if !c.has(uid) {
		c.MemberUIDs = append(c.MemberUIDs, uid)
	}
	s.mu.Unlock()
	s.changed(r.Context(), c)
	s.awardJoin(r.Context(), cl.UserID, uid)
	s.mu.Lock()
	out := *c
	out.MemberUIDs = append([]uint64(nil), c.MemberUIDs...)
	s.mu.Unlock()
	api.JSON(w, http.StatusOK, out)
}

var errForbidden = errors.New("forbidden")

func (s *Service) leaderConvoy(r *http.Request, cl auth.Claims) (*Convoy, error) {
	c := s.get(r.Context(), r.PathValue("id"))
	if c == nil || c.Ended {
		return nil, errors.New("not found")
	}
	uid, err := s.uid(r.Context(), cl.UserID)
	if err != nil || uid != c.LeaderUID {
		return nil, errForbidden
	}
	return c, nil
}

func (s *Service) fail(w http.ResponseWriter, err error) {
	if errors.Is(err, errForbidden) {
		api.Error(w, http.StatusForbidden, "leader only")
		return
	}
	api.Error(w, http.StatusNotFound, "not found")
}

func (s *Service) setDestination(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	c, err := s.leaderConvoy(r, cl)
	if err != nil {
		s.fail(w, err)
		return
	}
	var p place
	if api.Decode(r, &p) != nil || !geo.Valid(geo.E7(p.Lat), geo.E7(p.Lng)) {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	s.mu.Lock()
	c.Destination = &p
	s.mu.Unlock()
	s.changed(r.Context(), c)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) setRegroup(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	c, err := s.leaderConvoy(r, cl)
	if err != nil {
		s.fail(w, err)
		return
	}
	var p struct {
		Lat float64 `json:"lat"`
		Lng float64 `json:"lng"`
	}
	if api.Decode(r, &p) != nil || !geo.Valid(geo.E7(p.Lat), geo.E7(p.Lng)) {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	s.mu.Lock()
	c.Regroup = &regroup{Lat: p.Lat, Lng: p.Lng, SetAt: time.Now()}
	s.mu.Unlock()
	s.changed(r.Context(), c)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Service) end(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	c, err := s.leaderConvoy(r, cl)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.mu.Lock()
	c.Ended = true
	led := c.Destination != nil && len(c.MemberUIDs) >= 5
	s.mu.Unlock()
	s.changed(r.Context(), c)
	if led {
		s.award(r.Context(), cl.UserID, "convoy_lead")
	}
	w.WriteHeader(http.StatusNoContent)
}

// award records an achievement (plan 9.8). Convoy keys are awarded here because only the
// gateway sees convoys.
func (s *Service) award(ctx context.Context, userID, key string) {
	if pool := s.store.Pool(); pool != nil {
		_, _ = pool.Exec(ctx, `insert into public.achievements (user_id, key) values ($1, $2) on conflict do nothing`, userID, key)
	}
}

// awardJoin counts the convoys the user has been in (the mirror keeps member uids).
func (s *Service) awardJoin(ctx context.Context, userID string, uid uint64) {
	pool := s.store.Pool()
	if pool == nil {
		return
	}
	var n int
	_ = pool.QueryRow(ctx, `select count(*) from public.convoys where state->'member_uids' @> to_jsonb($1::bigint)`, int64(uid)).Scan(&n)
	if n >= 1 {
		s.award(ctx, userID, "convoy_1")
	}
	if n >= 3 {
		s.award(ctx, userID, "convoy_3")
	}
}

// invite pushes the join code to friends chosen by a member (M9 "Invite friends").
func (s *Service) invite(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	var b struct {
		UserIDs []string `json:"user_ids"`
	}
	if api.Decode(r, &b) != nil || len(b.UserIDs) == 0 || len(b.UserIDs) > 50 {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	c := s.get(r.Context(), r.PathValue("id"))
	uid, err := s.uid(r.Context(), cl.UserID)
	if c == nil || c.Ended || err != nil || !c.has(uid) {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	if s.push != nil {
		name := "A friend"
		if p, err := s.store.Profile(r.Context(), cl.UserID); err == nil && p.DisplayName != "" {
			name = p.DisplayName
		}
		go s.push.Send(context.WithoutCancel(r.Context()), b.UserIDs, push.Note{Kind: push.ConvoyInvites, Title: "Convoy invite",
			Body: name + " invited you to " + c.Name + ".", URL: "waypoints://invite/convoy/" + c.JoinCode,
			ActorID: cl.UserID, Dedupe: "convoy_invite:" + c.ID + ":" + cl.UserID})
	}
	w.WriteHeader(http.StatusAccepted)
}
