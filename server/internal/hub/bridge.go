package hub

import (
	"encoding/json"
	"strconv"
	"sync"
	"time"

	"waypoints/server/internal/bus"
	"waypoints/server/internal/privacy"
	"waypoints/server/internal/wire"
)

// bridge carries location between nodes over the bus (section 7.6). A node subscribes to
// u.<uid> and cell.<h3> only while it has a local subscriber to that topic, so updates for
// topics nobody watches elsewhere stay on the publisher's node. Received updates are fed to
// the local shards and never re-published.
type bridge struct {
	h    *Hub
	bus  bus.Bus
	node string

	mu     sync.Mutex
	refs   map[string]int
	unsubs map[string]func()
	infos  map[uint64]*Info
	pols   map[uint64]privacy.Policy // remote publishers, as last received
	local  map[uint64]privacy.Policy // local publishers, sent with every update
}

func (b *bridge) setLocalPolicy(uid uint64, p privacy.Policy) {
	b.mu.Lock()
	b.local[uid] = p
	b.mu.Unlock()
}

func (b *bridge) localPolicy(uid uint64) privacy.Policy {
	b.mu.Lock()
	defer b.mu.Unlock()
	if p, ok := b.local[uid]; ok {
		return p
	}
	return privacy.HiddenPolicy
}

type remoteUpdate struct {
	UID      uint64    `json:"u"`
	LatE7    int32     `json:"la"`
	LngE7    int32     `json:"ln"`
	Heading  uint32    `json:"h"`
	Tier     wire.Tier `json:"t"`
	AtMs     int64     `json:"at"`
	OriginMs uint64    `json:"o,omitempty"`
	Info     *Info     `json:"i,omitempty"`
}

type remoteMsg struct {
	Node    string          `json:"n"`
	Op      string          `json:"op"` // user, policy, offline, cell, leave
	UID     uint64          `json:"uid"`
	Precise *remoteUpdate   `json:"p,omitempty"`
	Approx  *remoteUpdate   `json:"a,omitempty"`
	Policy  *privacy.Policy `json:"pol,omitempty"`
	Cell    uint64          `json:"c,omitempty"`
}

func newBridge(h *Hub, b bus.Bus, node string) *bridge {
	return &bridge{h: h, bus: b, node: node, refs: map[string]int{}, unsubs: map[string]func(){},
		infos: map[uint64]*Info{}, pols: map[uint64]privacy.Policy{}, local: map[uint64]privacy.Policy{}}
}

func subject(t Topic) string {
	switch t.Kind {
	case KindUser:
		return "u." + strconv.FormatUint(t.Key, 10)
	case KindCell:
		return "cell." + strconv.FormatUint(t.Key, 10)
	}
	return ""
}

func encodeUpdate(u *Update) *remoteUpdate {
	if u == nil {
		return nil
	}
	return &remoteUpdate{UID: u.UID, LatE7: u.LatE7, LngE7: u.LngE7, Heading: u.Heading, Tier: u.Tier,
		AtMs: u.At.UnixMilli(), OriginMs: u.OriginMs, Info: u.Info}
}

// decodeUpdate reuses one *Info per publisher while it is unchanged, because outboxes treat
// the pointer as the info version.
func (b *bridge) decodeUpdate(r *remoteUpdate) *Update {
	if r == nil {
		return nil
	}
	b.mu.Lock()
	info := b.infos[r.UID]
	if r.Info != nil && (info == nil || *info != *r.Info) {
		info = r.Info
		b.infos[r.UID] = info
	}
	b.mu.Unlock()
	return &Update{UID: r.UID, LatE7: r.LatE7, LngE7: r.LngE7, Heading: r.Heading, Tier: r.Tier,
		At: time.UnixMilli(r.AtMs), OriginMs: r.OriginMs, Info: info}
}

func (b *bridge) publish(t Topic, m remoteMsg) {
	m.Node = b.node
	if data, err := json.Marshal(m); err == nil {
		_ = b.bus.Publish(subject(t), data)
	}
}

// ref tracks local interest in a topic and keeps the bus subscription in step.
func (b *bridge) ref(t Topic, delta int) {
	s := subject(t)
	if s == "" {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	b.refs[s] += delta
	switch n := b.refs[s]; {
	case n > 0 && b.unsubs[s] == nil:
		if un, err := b.bus.Subscribe(s, func(m bus.Msg) { b.ingest(t, m.Data) }); err == nil {
			b.unsubs[s] = un
		}
	case n <= 0:
		delete(b.refs, s)
		if un := b.unsubs[s]; un != nil {
			un()
			delete(b.unsubs, s)
		}
	}
}

func (b *bridge) ingest(t Topic, data []byte) {
	var m remoteMsg
	if json.Unmarshal(data, &m) != nil || m.Node == b.node {
		return
	}
	h := b.h
	if m.Policy != nil {
		b.mu.Lock()
		old, seen := b.pols[m.UID]
		changed := !seen || old != *m.Policy
		b.pols[m.UID] = *m.Policy
		b.mu.Unlock()
		if changed {
			h.send(cmd{op: opPolicy, topic: UserTopic(m.UID), policy: *m.Policy})
		}
	}
	switch m.Op {
	case "user":
		h.trySend(cmd{op: opPublishUser, topic: t, precise: b.decodeUpdate(m.Precise), approx: b.decodeUpdate(m.Approx)})
	case "offline":
		h.send(cmd{op: opOffline, topic: t})
	case "cell":
		if u := b.decodeUpdate(m.Precise); u != nil {
			h.trySend(cmd{op: opPublishCell, topic: t, precise: u})
		}
	case "leave":
		h.send(cmd{op: opLeaveCell, topic: t, uid: m.UID})
	}
}
