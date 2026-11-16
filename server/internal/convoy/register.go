// Package convoy keeps convoy state in memory on the node that created it,
// mirrors it to Postgres (table convoys) on every change so any node can load
// it, and serves the convoy endpoints of section 6. Members receive each
// other's precise positions through package ws while they are members.
//
// Multi-node (section 7.6): every node that has a convoy in its registry
// subscribes to c.<id> on the bus. Package ws publishes a member's precise
// updates ("pos") and leaves ("gone") there; changes to the convoy itself
// ride the same subject as "state" carrying the mirrored record, so every
// node's registry, member set, and connected members stay in step.
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
	"waypoints/server/internal/bus"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/hub"
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
	bus   bus.Bus // nil in single-node mode
	node  string

	mu     sync.Mutex
	byID   map[string]*Convoy
	byCode map[string]string
	unsub  map[string]func()    // c.<id> bus subscriptions for registry entries
	infos  map[uint64]*hub.Info // remote publishers' marker identities, deduplicated
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
		unsub:  map[string]func(){},
		infos:  map[uint64]*hub.Info{},
	}
	if b := bus.From(a); !b.Local() {
		s.bus = b
		s.node = a.Config.Node
	}
	s.push, _ = app.Lookup[*push.Service](a)
	v := app.MustLookup[*auth.Verifier](a)
	s.ws.SetConvoys(s)
	a.Mux.HandleFunc("POST /v1/convoys", api.Authed(v, s.create))
	a.Mux.HandleFunc("POST /v1/convoys/join", api.Authed(v, s.join))
	a.Mux.HandleFunc("PUT /v1/convoys/{id}/destination", api.Authed(v, s.setDestination))
	a.Mux.HandleFunc("PUT /v1/convoys/{id}/regroup", api.Authed(v, s.setRegroup))
	a.Mux.HandleFunc("DELETE /v1/convoys/{id}/regroup", api.Authed(v, s.clearRegroup))
	a.Mux.HandleFunc("DELETE /v1/convoys/{id}", api.Authed(v, s.end))
	a.Mux.HandleFunc("POST /v1/convoys/{id}/invite", api.Authed(v, s.invite))
	app.Provide(a, s)
}

// IsMember implements ws.ConvoyAuthority.
func (s *Service) IsMember(id string, uid uint64) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	c := s.get(ctx, id)
	if c == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return !c.Ended && c.has(uid)
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

// watch subscribes this node to c.<id> while the convoy is in the registry.
// Call it under s.mu wherever a convoy enters byID.
func (s *Service) watch(id string) {
	if s.bus == nil || s.unsub[id] != nil {
		return
	}
	if un, err := s.bus.Subscribe(ws.ConvoySubject(id), func(m bus.Msg) { s.ingest(id, m.Data) }); err == nil {
		s.unsub[id] = un
	}
}

// unwatch drops the c.<id> subscription. Call it under s.mu.
func (s *Service) unwatch(id string) {
	if un := s.unsub[id]; un != nil {
		un()
		delete(s.unsub, id)
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
	s.watch(c.ID)
	return &c
}

// changed mirrors to Postgres and sends ConvoyState to every member.
func (s *Service) changed(ctx context.Context, c *Convoy) {
	s.mu.Lock()
	raw, _ := json.Marshal(c)
	st := c.wire()
	members := append([]uint64(nil), c.MemberUIDs...)
	v := s.voice
	ended := c.Ended
	if ended {
		delete(s.byID, c.ID)
		delete(s.byCode, c.JoinCode)
		s.unwatch(c.ID)
	}
	s.mu.Unlock()
	if ended && v != nil {
		go v.ConvoyEnded(c.ID)
	}
	if pool := s.store.Pool(); pool != nil {
		_, _ = pool.Exec(ctx, `insert into public.convoys (id, join_code, state, ended, updated_at)
			values ($1, $2, $3, $4, now())
			on conflict (id) do update set state = excluded.state, ended = excluded.ended, updated_at = now()`,
			c.ID, c.JoinCode, raw, ended)
	}
	frame := &wire.ServerFrame{Body: &wire.ServerFrame_Convoy{Convoy: st}}
	for _, m := range members {
		s.ws.SendToUID(m, frame)
		if ended {
			s.ws.DropFromConvoy(c.ID, m)
		}
	}
	if s.bus != nil {
		if b, err := json.Marshal(ws.ConvoyBusMsg{Node: s.node, Op: "state", State: raw}); err == nil {
			_ = s.bus.Publish(ws.ConvoySubject(c.ID), b)
		}
	}
}

// ingest handles one c.<id> bus message for a convoy in this node's registry.
func (s *Service) ingest(id string, data []byte) {
	var m ws.ConvoyBusMsg
	if json.Unmarshal(data, &m) != nil || m.Node == s.node {
		return
	}
	switch m.Op {
	case "pos":
		u := m.Update
		if u == nil {
			return
		}
		// One *hub.Info per remote publisher while unchanged: outboxes version
		// identity by pointer, like the hub bridge does.
		s.mu.Lock()
		info := s.infos[m.UID]
		if u.Info != nil && (info == nil || *info != *u.Info) {
			info = u.Info
			s.infos[m.UID] = info
		}
		s.mu.Unlock()
		s.ws.DeliverConvoy(id, &hub.Update{UID: m.UID, LatE7: u.LatE7, LngE7: u.LngE7, Heading: u.Heading,
			Tier: wire.Tier_PRECISE, At: time.UnixMilli(u.AtMs), OriginMs: u.OriginMs, Info: info, Remote: true})
	case "gone":
		s.ws.DropConvoyMember(id, m.UID)
	case "state":
		s.applyRemote(id, m.State)
	}
}

// applyRemote folds a "state" message into the registry so this node agrees on
// membership (CNV-9): members dropped elsewhere are detached here too, local
// members get the fresh ConvoyState, and an ended convoy leaves the registry.
func (s *Service) applyRemote(id string, raw json.RawMessage) {
	var c Convoy
	if json.Unmarshal(raw, &c) != nil || c.ID != id {
		return
	}
	s.mu.Lock()
	old := s.byID[id]
	if c.Ended {
		delete(s.byID, id)
		delete(s.byCode, c.JoinCode)
		s.unwatch(id)
	} else {
		s.byID[id] = &c
		s.byCode[c.JoinCode] = id
		s.watch(id)
	}
	var removed []uint64
	if old != nil {
		for _, uid := range old.MemberUIDs {
			if !c.has(uid) {
				removed = append(removed, uid)
			}
		}
	}
	s.mu.Unlock()
	frame := &wire.ServerFrame{Body: &wire.ServerFrame_Convoy{Convoy: c.wire()}}
	for _, m := range c.MemberUIDs {
		s.ws.SendToUID(m, frame)
		if c.Ended {
			s.ws.DropFromConvoy(id, m)
		}
	}
	for _, uid := range removed {
		s.ws.DropFromConvoy(id, uid)
	}
}

// maxPolyline caps a convoy route: a saved road is at most a few thousand points.
const maxPolyline = 64 << 10

const codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// Join codes are 6 characters from a 32-character alphabet (~1B values), so
// guessing is impractical; the per-user join limit below makes scripted
// guessing infeasible on top of that.
var (
	createLimit = api.NewLimiter(10, time.Hour) // convoys created per user
	joinLimit   = api.NewLimiter(30, time.Hour) // join attempts per user
)

func validJoinCode(code string) bool {
	if len(code) != 6 {
		return false
	}
	for i := 0; i < len(code); i++ {
		if !strings.ContainsRune(codeAlphabet, rune(code[i])) {
			return false
		}
	}
	return true
}

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
	if api.Decode(r, &b) != nil || len([]rune(b.Name)) > 40 || len(b.Polyline) > maxPolyline ||
		(b.Destination != nil && !geo.Valid(geo.E7(b.Destination.Lat), geo.E7(b.Destination.Lng))) {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if !createLimit.Allow(cl.UserID) {
		api.Error(w, http.StatusTooManyRequests, "rate limited")
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
	s.watch(c.ID)
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
	if !validJoinCode(code) || !joinLimit.Allow(cl.UserID) {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	s.mu.Lock()
	id := s.byCode[code]
	c := s.byID[id]
	s.mu.Unlock()
	if c == nil {
		c = s.load(r.Context(), "join_code = $1", code)
	}
	if c == nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	uid, err := s.uid(r.Context(), cl.UserID)
	if err != nil {
		api.Error(w, http.StatusUnauthorized, "no profile")
		return
	}
	s.mu.Lock()
	ended := c.Ended
	if !ended && !c.has(uid) {
		c.MemberUIDs = append(c.MemberUIDs, uid)
	}
	s.mu.Unlock()
	if ended {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
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
	if c == nil {
		return nil, errors.New("not found")
	}
	uid, err := s.uid(r.Context(), cl.UserID)
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.Ended {
		return nil, errors.New("not found")
	}
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

// setRegroup drops the regroup point; any member may (CNV-12).
func (s *Service) setRegroup(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	c := s.get(r.Context(), r.PathValue("id"))
	uid, err := s.uid(r.Context(), cl.UserID)
	if c != nil {
		s.mu.Lock()
		if c.Ended || !c.has(uid) {
			c = nil
		}
		s.mu.Unlock()
	}
	if c == nil || err != nil {
		api.Error(w, http.StatusNotFound, "not found")
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

// clearRegroup is the leader's "Rolling" (CNV-12).
func (s *Service) clearRegroup(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	c, err := s.leaderConvoy(r, cl)
	if err != nil {
		s.fail(w, err)
		return
	}
	s.mu.Lock()
	c.Regroup = nil
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
	if c != nil {
		s.mu.Lock()
		if c.Ended || !c.has(uid) {
			c = nil
		}
		s.mu.Unlock()
	}
	if c == nil || err != nil {
		api.Error(w, http.StatusNotFound, "not found")
		return
	}
	// Only accepted friends, never across a block (the POST /v1/eta check).
	ids := b.UserIDs
	if pool := s.store.Pool(); pool != nil {
		rows, err := pool.Query(r.Context(), `select u::text from unnest($2::uuid[]) u
			where exists (select 1 from public.friendships f where f.status = 'accepted'
				and least(f.requester_id, f.addressee_id) = least(u, $1::uuid)
				and greatest(f.requester_id, f.addressee_id) = greatest(u, $1::uuid))
			and not exists (select 1 from public.blocks k where (k.blocker_id = u and k.blocked_id = $1::uuid)
				or (k.blocker_id = $1::uuid and k.blocked_id = u))`, cl.UserID, b.UserIDs)
		if err != nil {
			api.Error(w, http.StatusBadRequest, "user_ids")
			return
		}
		ids = ids[:0]
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				ids = append(ids, id)
			}
		}
		rows.Close()
	}
	if len(ids) > 0 && s.push != nil {
		name := "A friend"
		if p, err := s.store.Profile(r.Context(), cl.UserID); err == nil && p.DisplayName != "" {
			name = p.DisplayName
		}
		go s.push.Send(context.WithoutCancel(r.Context()), ids, push.Note{Kind: push.ConvoyInvites, Title: "Convoy invite",
			Body: name + " invited you to " + c.Name + ".", URL: "waypoints://invite/convoy/" + c.JoinCode,
			ActorID: cl.UserID, Dedupe: "convoy_invite:" + c.ID + ":" + cl.UserID})
	}
	w.WriteHeader(http.StatusAccepted)
}
