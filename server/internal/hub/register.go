// Package hub is the cell-sharded fan-out core (section 7.2 and 7.3).
//
// Topics are user subjects (u.<uid>: a publisher's friends and teammates),
// cell subjects (cell.<h3r7>: nearby strangers), and aggregate subjects
// (agg.<h3r5>: counts for large viewports). Each topic hashes to one of
// S = 2 x GOMAXPROCS shard goroutines, which owns that topic's subscribers and
// last-known positions with no locks. Commands reach a shard over a bounded
// channel; location publishes are dropped (and counted) when it is full,
// everything else blocks.
//
// A shard never touches a socket. It hands updates to a Sink (the
// connection's outbox, package ws), which conflates them until the writer's
// next tick.
//
// Privacy: a user topic holds the publisher's current effective Policy. For
// each subscriber the shard picks the precise form, the approximate form, or
// nothing, by the level the policy gives that subscriber's relation; when the
// policy changes it re-decides and sends gone where visibility was lost. This
// is the single-node form of attaching subscribers to u.<uid>.p or u.<uid>.a.
package hub

import (
	"runtime"
	"time"

	"waypoints/server/internal/app"
	"waypoints/server/internal/metrics"
	"waypoints/server/internal/privacy"
	"waypoints/server/internal/wire"
)

// Kind is a topic family.
type Kind uint8

const (
	KindUser Kind = iota + 1 // key: publisher uid
	KindCell                 // key: H3 resolution 7 cell
	KindAgg                  // key: H3 resolution 5 cell
)

// Topic identifies one subject. It is comparable and cheap to copy.
type Topic struct {
	Kind Kind
	Key  uint64
}

// Info is a publisher's marker identity. A connection builds one per profile
// version; pointer identity is the version, so it must not be mutated.
type Info struct {
	MarkerIcon  string
	MarkerTrail string
	PaintRGB    uint32
	DisplayName string
	CarLabel    string
}

// Update is one published position, shared read-only by every sink it reaches.
type Update struct {
	UID          uint64
	LatE7, LngE7 int32
	Heading      uint32 // 360 when unknown or approximate
	Tier         wire.Tier
	At           time.Time // when the gateway accepted the fix
	OriginMs     uint64    // publisher client_ms, only under -bench
	Info         *Info
}

// Sink receives deliveries. Implementations must be fast and non-blocking:
// they are called from shard goroutines.
type Sink interface {
	ViewerUID() uint64
	Blocks(uid uint64) bool
	Deliver(src Topic, rel wire.Relation, u *Update)
	Gone(src Topic, uid uint64)
	Aggregate(src Topic, h3 uint64, count uint32)
}

type op uint8

const (
	opSub op = iota + 1
	opUnsub
	opPolicy
	opPublishUser
	opPublishCell
	opLeaveCell
	opJoinAgg
	opLeaveAgg
	opOffline
)

type cmd struct {
	op      op
	topic   Topic
	sink    Sink
	rel     wire.Relation
	precise *Update // opPublishUser; opPublishCell uses it for the nearby form
	approx  *Update
	uid     uint64
	policy  privacy.Policy
}

// QueueSize is each shard's command channel capacity.
const QueueSize = 4096

// Hub routes commands to shards.
type Hub struct {
	shards []*shard
	m      *hubMetrics
}

type hubMetrics struct {
	publishes  *metrics.Counter
	deliveries *metrics.Counter
	dropped    *metrics.Counter
	gone       *metrics.Counter
}

// Register provides *Hub and starts its shards with the app.
func Register(a *app.App) {
	h := New(2*runtime.GOMAXPROCS(0), a.Metrics)
	for _, s := range h.shards {
		a.Go("hub-shard", s.run)
	}
	app.Provide(a, h)
}

// New builds a hub with n shards. Call each shard's run (Register does).
func New(n int, reg *metrics.Registry) *Hub {
	if n < 1 {
		n = 1
	}
	m := &hubMetrics{
		publishes:  reg.Counter("hub_publishes_total", "Location publishes accepted by a shard.", nil),
		deliveries: reg.Counter("hub_deliveries_total", "Entity updates handed to connection outboxes.", nil),
		dropped:    reg.Counter("hub_publish_dropped_total", "Location publishes dropped because a shard queue was full.", nil),
		gone:       reg.Counter("hub_gone_total", "Gone notices handed to connection outboxes.", nil),
	}
	h := &Hub{m: m}
	for range n {
		h.shards = append(h.shards, newShard(m))
	}
	reg.GaugeFunc("hub_shards", "Shard goroutines.", nil, func() float64 { return float64(len(h.shards)) })
	reg.GaugeFunc("hub_queue_depth", "Commands waiting across all shard queues.", nil, func() float64 {
		n := 0
		for _, s := range h.shards {
			n += len(s.in)
		}
		return float64(n)
	})
	return h
}

func (h *Hub) shardFor(t Topic) *shard {
	x := t.Key*0x9E3779B97F4A7C15 ^ uint64(t.Kind)<<56
	x ^= x >> 29
	return h.shards[x%uint64(len(h.shards))]
}

func (h *Hub) send(c cmd) { h.shardFor(c.topic).in <- c }

func (h *Hub) trySend(c cmd) {
	select {
	case h.shardFor(c.topic).in <- c:
	default:
		h.m.dropped.Inc()
	}
}

// UserTopic, CellTopic, and AggTopic build topics.
func UserTopic(uid uint64) Topic  { return Topic{KindUser, uid} }
func CellTopic(h3r7 uint64) Topic { return Topic{KindCell, h3r7} }
func AggTopic(h3r5 uint64) Topic  { return Topic{KindAgg, h3r5} }

// Subscribe attaches sink to t. For user topics rel is FRIEND or TEAMMATE;
// cell and aggregate topics ignore it. The shard replies with a snapshot.
func (h *Hub) Subscribe(t Topic, s Sink, rel wire.Relation) {
	h.send(cmd{op: opSub, topic: t, sink: s, rel: rel})
}

// Unsubscribe detaches sink from t and sends it gone for what t showed.
func (h *Hub) Unsubscribe(t Topic, s Sink) { h.send(cmd{op: opUnsub, topic: t, sink: s}) }

// SetPolicy sets a publisher's effective policy.
func (h *Hub) SetPolicy(uid uint64, p privacy.Policy) {
	h.send(cmd{op: opPolicy, topic: UserTopic(uid), policy: p})
}

// PublishUser publishes to the publisher's friends and teammates. Either form
// may be nil (approx is produced at most every 15 s).
func (h *Hub) PublishUser(uid uint64, precise, approx *Update) {
	h.trySend(cmd{op: opPublishUser, topic: UserTopic(uid), precise: precise, approx: approx})
}

// PublishCell publishes the nearby form to a cell.
func (h *Hub) PublishCell(h3r7 uint64, u *Update) {
	h.trySend(cmd{op: opPublishCell, topic: CellTopic(h3r7), precise: u})
}

// LeaveCell removes a publisher from a cell and sends gone to its viewers.
func (h *Hub) LeaveCell(h3r7, uid uint64) {
	h.send(cmd{op: opLeaveCell, topic: CellTopic(h3r7), uid: uid})
}

// JoinAgg and LeaveAgg maintain aggregate membership.
func (h *Hub) JoinAgg(h3r5, uid uint64)  { h.send(cmd{op: opJoinAgg, topic: AggTopic(h3r5), uid: uid}) }
func (h *Hub) LeaveAgg(h3r5, uid uint64) { h.send(cmd{op: opLeaveAgg, topic: AggTopic(h3r5), uid: uid}) }

// Offline clears a publisher's user topic and sends gone to its viewers.
func (h *Hub) Offline(uid uint64) { h.send(cmd{op: opOffline, topic: UserTopic(uid)}) }
