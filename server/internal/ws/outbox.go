package ws

import (
	"sync"
	"time"

	"waypoints/server/internal/hub"
	"waypoints/server/internal/wire"
)

// ReliableQueue is the reliable lane's capacity (section 6). Overflow closes
// the connection with 4008.
const ReliableQueue = 64

type srcState struct {
	u   *hub.Update
	rel wire.Relation
}

// entity is what one viewer knows about one publisher: the sources currently
// showing it (a friend may arrive on u.<uid> and on a cell at once) and what
// the client was last sent.
type entity struct {
	sources  map[hub.Topic]srcState
	visible  bool // the client has been sent this uid since its last gone
	sentInfo *hub.Info
	sentRel  wire.Relation
}

// best is the highest-tier source, newest first on a tie.
func (e *entity) best() srcState {
	var b srcState
	for _, s := range e.sources {
		if b.u == nil || s.u.Tier > b.u.Tier || (s.u.Tier == b.u.Tier && s.u.At.After(b.u.At)) {
			b = s
		}
	}
	return b
}

// Outbox is one connection's pair of lanes. Shards write the conflated lane
// under mu (a few map operations, never I/O); the writer goroutine swaps it
// out once per tick. The reliable lane is a bounded channel of encoded frames.
type Outbox struct {
	viewer  uint64
	blocked map[uint64]struct{} // read-only after construction

	mu      sync.Mutex
	ents    map[uint64]*entity
	pending map[uint64]srcState
	gone    map[uint64]struct{}
	aggs    map[uint64]uint32

	signal   chan struct{} // capacity 1: something is dirty
	reliable chan []byte
	overflow func() // called once, from whichever goroutine overflowed
	once     sync.Once
}

func newOutbox(viewer uint64, blocked []uint64, overflow func()) *Outbox {
	b := make(map[uint64]struct{}, len(blocked))
	for _, u := range blocked {
		b[u] = struct{}{}
	}
	return &Outbox{
		viewer:   viewer,
		blocked:  b,
		ents:     map[uint64]*entity{},
		pending:  map[uint64]srcState{},
		gone:     map[uint64]struct{}{},
		aggs:     map[uint64]uint32{},
		signal:   make(chan struct{}, 1),
		reliable: make(chan []byte, ReliableQueue),
		overflow: overflow,
	}
}

func (o *Outbox) ViewerUID() uint64 { return o.viewer }

func (o *Outbox) Blocks(uid uint64) bool {
	_, ok := o.blocked[uid]
	return ok
}

func (o *Outbox) markDirty() {
	select {
	case o.signal <- struct{}{}:
	default:
	}
}

// Deliver records u from src and queues it if it is now the best view of
// that publisher. Newest overwrites: this is the conflation.
func (o *Outbox) Deliver(src hub.Topic, rel wire.Relation, u *hub.Update) {
	if u.UID == o.viewer {
		return
	}
	o.mu.Lock()
	e := o.ents[u.UID]
	if e == nil {
		e = &entity{sources: map[hub.Topic]srcState{}}
		o.ents[u.UID] = e
	}
	e.sources[src] = srcState{u, rel}
	if b := e.best(); b.u == u {
		o.pending[u.UID] = b
		delete(o.gone, u.UID)
	}
	o.mu.Unlock()
	o.markDirty()
}

// Gone removes src as a source of uid. When nothing shows uid any more the
// client is told it is gone; otherwise it gets the best remaining form, so a
// precise position never lingers after the precise source goes away.
func (o *Outbox) Gone(src hub.Topic, uid uint64) {
	o.mu.Lock()
	e := o.ents[uid]
	if e == nil {
		o.mu.Unlock()
		return
	}
	if _, ok := e.sources[src]; !ok {
		o.mu.Unlock()
		return
	}
	delete(e.sources, src)
	if len(e.sources) == 0 {
		delete(o.ents, uid)
		delete(o.pending, uid)
		if e.visible {
			o.gone[uid] = struct{}{}
		}
	} else {
		o.pending[uid] = e.best()
	}
	o.mu.Unlock()
	o.markDirty()
}

func (o *Outbox) Aggregate(_ hub.Topic, h3 uint64, count uint32) {
	o.mu.Lock()
	o.aggs[h3] = count
	o.mu.Unlock()
	o.markDirty()
}

// Enqueue puts an encoded frame on the reliable lane without blocking. A full
// lane means the client is not reading: the connection is closed as a slow
// consumer.
func (o *Outbox) Enqueue(frame []byte) bool {
	select {
	case o.reliable <- frame:
		return true
	default:
		o.once.Do(o.overflow)
		return false
	}
}

// depth is the conflated entries plus queued reliable frames.
func (o *Outbox) depth() int {
	o.mu.Lock()
	n := len(o.pending) + len(o.gone) + len(o.aggs)
	o.mu.Unlock()
	return n + len(o.reliable)
}

// take swaps out the conflated lane and builds the Batch, or returns nil when
// there is nothing to send.
func (o *Outbox) take(now time.Time, bench bool) *wire.Batch {
	o.mu.Lock()
	if len(o.pending) == 0 && len(o.gone) == 0 && len(o.aggs) == 0 {
		o.mu.Unlock()
		return nil
	}
	b := &wire.Batch{ServerMs: uint64(now.UnixMilli())}
	if len(o.pending) > 0 {
		b.Updates = make([]*wire.EntityUpdate, 0, len(o.pending))
	}
	for uid, s := range o.pending {
		e := o.ents[uid]
		eu := &wire.EntityUpdate{
			Uid: uid, LatE7: s.u.LatE7, LngE7: s.u.LngE7, HeadingDeg: s.u.Heading, Tier: s.u.Tier,
			AgeDs: ageDs(now, s.u.At),
		}
		if bench {
			eu.OriginMs = s.u.OriginMs
		}
		if e != nil {
			if !e.visible || e.sentInfo != s.u.Info || e.sentRel != s.rel {
				eu.Info = infoFor(s.u.Info, s.rel)
				e.sentInfo, e.sentRel = s.u.Info, s.rel
			}
			e.visible = true
		}
		b.Updates = append(b.Updates, eu)
	}
	for uid := range o.gone {
		b.Gone = append(b.Gone, uid)
	}
	for h, n := range o.aggs {
		b.Aggregates = append(b.Aggregates, &wire.CellAggregate{H3: h, Count: n})
	}
	clear(o.pending)
	clear(o.gone)
	clear(o.aggs)
	o.mu.Unlock()
	return b
}

func ageDs(now, at time.Time) uint32 {
	d := now.Sub(at)
	if d < 0 {
		return 0
	}
	return uint32(d / (100 * time.Millisecond))
}

// infoFor builds EntityInfo for a relation. Strangers get no name and no car.
func infoFor(in *hub.Info, rel wire.Relation) *wire.EntityInfo {
	if in == nil {
		return &wire.EntityInfo{Relation: rel}
	}
	out := &wire.EntityInfo{Relation: rel, MarkerIcon: in.MarkerIcon, MarkerTrail: in.MarkerTrail, PaintRgb: in.PaintRGB}
	if rel != wire.Relation_NEARBY {
		out.DisplayName = in.DisplayName
		out.CarLabel = in.CarLabel
	}
	return out
}
