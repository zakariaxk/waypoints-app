// Package bus defines the inter-node message bus (section 7.6) and its
// in-process implementation, used in single-node mode.
//
// In single-node mode the hub delivers location to local subscribers directly
// and the bus carries only control traffic, such as acl.<uid> privacy
// invalidations. natsbus (wave 3) implements the same interface over NATS core.
package bus

import (
	"context"
	"sync"
	"time"

	"waypoints/server/internal/app"
)

// Msg is one delivered message. Reply is non-nil for requests.
type Msg struct {
	Subject string
	Data    []byte
	Reply   func(data []byte)
}

// Handler receives messages. It runs on the publisher's goroutine (in-process)
// or the bus client's goroutine (NATS), so it must not block.
type Handler func(Msg)

// Bus is the inter-node bus. Delivery is at most once.
type Bus interface {
	Publish(subject string, data []byte) error
	// Subscribe registers h for an exact subject. Call the returned function to
	// unsubscribe; it is safe to call more than once.
	Subscribe(subject string, h Handler) (unsubscribe func(), err error)
	// Request publishes data and collects replies until window elapses or ctx
	// ends. The in-process bus returns as soon as local handlers have replied.
	Request(ctx context.Context, subject string, data []byte, window time.Duration) ([][]byte, error)
	// Local reports whether every subscriber lives in this process.
	Local() bool
}

// Register provides the in-process bus unless NATS_URL selects natsbus.
func Register(a *app.App) {
	if a.Config.NATSURL != "" {
		return
	}
	app.Provide[Bus](a, NewInProc())
}

// From returns the process bus. If NATS_URL is set but no NATS implementation
// registered (natsbus not built yet), it falls back to the in-process bus.
func From(a *app.App) Bus {
	if b, ok := app.Lookup[Bus](a); ok {
		return b
	}
	a.Log.Warn("NATS_URL is set but no NATS bus is registered; using the in-process bus")
	b := NewInProc()
	app.Provide[Bus](a, b)
	return b
}

type sub struct {
	id uint64
	h  Handler
}

// InProc is the single-node bus: a subject map under a read-write lock.
type InProc struct {
	mu     sync.RWMutex
	nextID uint64
	subs   map[string][]sub
}

// NewInProc returns an empty in-process bus.
func NewInProc() *InProc { return &InProc{subs: map[string][]sub{}} }

func (b *InProc) Local() bool { return true }

func (b *InProc) Publish(subject string, data []byte) error {
	b.mu.RLock()
	hs := b.subs[subject]
	b.mu.RUnlock()
	for _, s := range hs {
		s.h(Msg{Subject: subject, Data: data})
	}
	return nil
}

func (b *InProc) Subscribe(subject string, h Handler) (func(), error) {
	b.mu.Lock()
	b.nextID++
	id := b.nextID
	// Copy on write so Publish can iterate a snapshot without the lock.
	cur := b.subs[subject]
	next := make([]sub, len(cur), len(cur)+1)
	copy(next, cur)
	b.subs[subject] = append(next, sub{id: id, h: h})
	b.mu.Unlock()

	var once sync.Once
	return func() {
		once.Do(func() {
			b.mu.Lock()
			defer b.mu.Unlock()
			cur := b.subs[subject]
			next := make([]sub, 0, len(cur))
			for _, s := range cur {
				if s.id != id {
					next = append(next, s)
				}
			}
			if len(next) == 0 {
				delete(b.subs, subject)
			} else {
				b.subs[subject] = next
			}
		})
	}, nil
}

func (b *InProc) Request(ctx context.Context, subject string, data []byte, _ time.Duration) ([][]byte, error) {
	b.mu.RLock()
	hs := b.subs[subject]
	b.mu.RUnlock()
	var mu sync.Mutex
	var out [][]byte
	reply := func(d []byte) {
		mu.Lock()
		out = append(out, d)
		mu.Unlock()
	}
	for _, s := range hs {
		if ctx.Err() != nil {
			break
		}
		s.h(Msg{Subject: subject, Data: data, Reply: reply})
	}
	mu.Lock()
	defer mu.Unlock()
	return out, ctx.Err()
}
