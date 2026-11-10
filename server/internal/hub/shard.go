package hub

import (
	"context"
	"time"

	"waypoints/server/internal/privacy"
	"waypoints/server/internal/store"
	"waypoints/server/internal/wire"
)

type userTopic struct {
	subs    map[Sink]wire.Relation
	policy  privacy.Policy
	precise *Update
	approx  *Update
}

type cellTopic struct {
	subs map[Sink]struct{}
	last map[uint64]*Update
}

type aggTopic struct {
	subs    map[Sink]struct{}
	members map[uint64]struct{}
	dirty   bool
}

// shard owns the state of the topics hashing to it. Only its goroutine reads
// or writes these maps.
type shard struct {
	in    chan cmd
	m     *hubMetrics
	users map[uint64]*userTopic
	cells map[uint64]*cellTopic
	aggs  map[uint64]*aggTopic
}

func newShard(m *hubMetrics) *shard {
	return &shard{
		in:    make(chan cmd, QueueSize),
		m:     m,
		users: map[uint64]*userTopic{},
		cells: map[uint64]*cellTopic{},
		aggs:  map[uint64]*aggTopic{},
	}
}

func (s *shard) run(ctx context.Context) {
	agg := time.NewTicker(time.Second)
	defer agg.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case c := <-s.in:
			s.handle(c)
		case <-agg.C:
			s.flushAggs()
		}
	}
}

// formFor picks what a subscriber with relation rel sees under policy p.
func formFor(p privacy.Policy, rel wire.Relation, precise, approx *Update) *Update {
	switch p.For(rel) {
	case store.Precise:
		return precise
	case store.Approx:
		return approx
	}
	return nil
}

func (s *shard) user(uid uint64, create bool) *userTopic {
	t := s.users[uid]
	if t == nil && create {
		t = &userTopic{subs: map[Sink]wire.Relation{}, policy: privacy.HiddenPolicy}
		s.users[uid] = t
	}
	return t
}

func (s *shard) cell(h uint64, create bool) *cellTopic {
	t := s.cells[h]
	if t == nil && create {
		t = &cellTopic{subs: map[Sink]struct{}{}, last: map[uint64]*Update{}}
		s.cells[h] = t
	}
	return t
}

func (s *shard) agg(h uint64, create bool) *aggTopic {
	t := s.aggs[h]
	if t == nil && create {
		t = &aggTopic{subs: map[Sink]struct{}{}, members: map[uint64]struct{}{}}
		s.aggs[h] = t
	}
	return t
}

func (s *shard) gc(tp Topic) {
	switch tp.Kind {
	case KindUser:
		if t := s.users[tp.Key]; t != nil && len(t.subs) == 0 && t.precise == nil && t.approx == nil && t.policy == privacy.HiddenPolicy {
			delete(s.users, tp.Key)
		}
	case KindCell:
		if t := s.cells[tp.Key]; t != nil && len(t.subs) == 0 && len(t.last) == 0 {
			delete(s.cells, tp.Key)
		}
	case KindAgg:
		if t := s.aggs[tp.Key]; t != nil && len(t.subs) == 0 && len(t.members) == 0 {
			delete(s.aggs, tp.Key)
		}
	}
}

func (s *shard) deliver(sink Sink, src Topic, rel wire.Relation, u *Update) {
	sink.Deliver(src, rel, u)
	s.m.deliveries.Inc()
}

func (s *shard) gone(sink Sink, src Topic, uid uint64) {
	sink.Gone(src, uid)
	s.m.gone.Inc()
}

func (s *shard) handle(c cmd) {
	tp := c.topic
	switch c.op {
	case opSub:
		switch tp.Kind {
		case KindUser:
			t := s.user(tp.Key, true)
			t.subs[c.sink] = c.rel
			if u := formFor(t.policy, c.rel, t.precise, t.approx); u != nil {
				s.deliver(c.sink, tp, c.rel, u)
			}
		case KindCell:
			t := s.cell(tp.Key, true)
			t.subs[c.sink] = struct{}{}
			viewer := c.sink.ViewerUID()
			for uid, u := range t.last {
				if uid != viewer && !c.sink.Blocks(uid) {
					s.deliver(c.sink, tp, wire.Relation_NEARBY, u)
				}
			}
		case KindAgg:
			t := s.agg(tp.Key, true)
			t.subs[c.sink] = struct{}{}
			c.sink.Aggregate(tp, tp.Key, uint32(len(t.members)))
		}

	case opUnsub:
		switch tp.Kind {
		case KindUser:
			if t := s.user(tp.Key, false); t != nil {
				if _, ok := t.subs[c.sink]; ok {
					delete(t.subs, c.sink)
					s.gone(c.sink, tp, tp.Key)
				}
			}
		case KindCell:
			if t := s.cell(tp.Key, false); t != nil {
				if _, ok := t.subs[c.sink]; ok {
					delete(t.subs, c.sink)
					for uid := range t.last {
						s.gone(c.sink, tp, uid)
					}
				}
			}
		case KindAgg:
			if t := s.agg(tp.Key, false); t != nil {
				delete(t.subs, c.sink)
			}
		}
		s.gc(tp)

	case opPolicy:
		t := s.user(tp.Key, true)
		old := t.policy
		t.policy = c.policy
		for sink, rel := range t.subs {
			before := formFor(old, rel, t.precise, t.approx)
			after := formFor(c.policy, rel, t.precise, t.approx)
			switch {
			case after == nil && before != nil:
				s.gone(sink, tp, tp.Key)
			case after != nil && after != before:
				s.deliver(sink, tp, rel, after)
			}
		}
		s.gc(tp)

	case opPublishUser:
		t := s.user(tp.Key, true)
		if c.precise != nil {
			t.precise = c.precise
		}
		if c.approx != nil {
			t.approx = c.approx
		}
		s.m.publishes.Inc()
		for sink, rel := range t.subs {
			switch t.policy.For(rel) {
			case store.Precise:
				if c.precise != nil {
					s.deliver(sink, tp, rel, c.precise)
				}
			case store.Approx:
				if c.approx != nil {
					s.deliver(sink, tp, rel, c.approx)
				}
			}
		}

	case opOffline:
		if t := s.user(tp.Key, false); t != nil {
			t.precise, t.approx = nil, nil
			t.policy = privacy.HiddenPolicy
			for sink := range t.subs {
				s.gone(sink, tp, tp.Key)
			}
			s.gc(tp)
		}

	case opPublishCell:
		u := c.precise
		t := s.cell(tp.Key, true)
		t.last[u.UID] = u
		s.m.publishes.Inc()
		for sink := range t.subs {
			if sink.ViewerUID() != u.UID && !sink.Blocks(u.UID) {
				s.deliver(sink, tp, wire.Relation_NEARBY, u)
			}
		}

	case opLeaveCell:
		if t := s.cell(tp.Key, false); t != nil {
			if _, ok := t.last[c.uid]; ok {
				delete(t.last, c.uid)
				for sink := range t.subs {
					s.gone(sink, tp, c.uid)
				}
			}
			s.gc(tp)
		}

	case opJoinAgg:
		t := s.agg(tp.Key, true)
		if _, ok := t.members[c.uid]; !ok {
			t.members[c.uid] = struct{}{}
			t.dirty = true
		}

	case opLeaveAgg:
		if t := s.agg(tp.Key, false); t != nil {
			if _, ok := t.members[c.uid]; ok {
				delete(t.members, c.uid)
				t.dirty = true
			}
			if len(t.subs) == 0 {
				s.gc(tp)
			}
		}
	}
}

// flushAggs sends changed counts once per second.
func (s *shard) flushAggs() {
	for h, t := range s.aggs {
		if !t.dirty {
			continue
		}
		t.dirty = false
		n := uint32(len(t.members))
		for sink := range t.subs {
			sink.Aggregate(AggTopic(h), h, n)
		}
		s.gc(AggTopic(h))
	}
}
