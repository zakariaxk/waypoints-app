package ws

import (
	"encoding/json"

	"waypoints/server/internal/hub"
	"waypoints/server/internal/wire"
)

// ConvoySubject is the bus subject carrying a convoy's precise positions,
// member leaves, and state changes between nodes (plan 7.4: c.<convoy_id>).
// Package convoy subscribes while the convoy is in its local registry.
func ConvoySubject(id string) string { return "c." + id }

// ConvoyBusMsg is the envelope on a convoy subject. Node lets a node skip its
// own echo; ops are "pos" (a member's precise update), "gone" (a member left
// or disconnected), and "state" (the full convoy record, handled by package
// convoy).
type ConvoyBusMsg struct {
	Node   string           `json:"n"`
	Op     string           `json:"op"`
	UID    uint64           `json:"uid,omitempty"`
	Update *ConvoyBusUpdate `json:"u,omitempty"`
	State  json.RawMessage  `json:"s,omitempty"`
}

// ConvoyBusUpdate is the "pos" payload: the same fields the hub bridge sends
// for a precise update.
type ConvoyBusUpdate struct {
	LatE7    int32     `json:"la"`
	LngE7    int32     `json:"ln"`
	Heading  uint32    `json:"h"`
	AtMs     int64     `json:"at"`
	OriginMs uint64    `json:"o,omitempty"`
	Info     *hub.Info `json:"i,omitempty"`
}

// publishConvoyPos sends a member's precise update to other nodes' members.
func (s *Server) publishConvoyPos(id string, u *hub.Update) {
	if !s.multi {
		return
	}
	b, err := json.Marshal(ConvoyBusMsg{Node: s.a.Config.Node, Op: "pos", UID: u.UID,
		Update: &ConvoyBusUpdate{LatE7: u.LatE7, LngE7: u.LngE7, Heading: u.Heading,
			AtMs: u.At.UnixMilli(), OriginMs: u.OriginMs, Info: u.Info}})
	if err == nil {
		_ = s.bus.Publish(ConvoySubject(id), b)
	}
}

// publishConvoyGone tells other nodes' members to drop uid as a convoy source.
func (s *Server) publishConvoyGone(id string, uid uint64) {
	if !s.multi {
		return
	}
	b, err := json.Marshal(ConvoyBusMsg{Node: s.a.Config.Node, Op: "gone", UID: uid})
	if err == nil {
		_ = s.bus.Publish(ConvoySubject(id), b)
	}
}

// DeliverConvoy hands a remote member's precise update to this node's members
// of the convoy; package convoy calls it for each "pos" message.
func (s *Server) DeliverConvoy(id string, u *hub.Update) {
	topic := hub.Topic{Kind: KindConvoy, Key: convoyKey(id)}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for m := range s.convoys[id] {
		if m.uid != u.UID && !m.out.Blocks(u.UID) {
			m.out.Deliver(topic, wire.Relation_CONVOY, u)
		}
	}
}

// DropConvoyMember removes uid as a convoy source for this node's members;
// package convoy calls it for each "gone" message.
func (s *Server) DropConvoyMember(id string, uid uint64) {
	topic := hub.Topic{Kind: KindConvoy, Key: convoyKey(id)}
	s.mu.RLock()
	defer s.mu.RUnlock()
	for m := range s.convoys[id] {
		m.out.Gone(topic, uid)
	}
}
