package store

import (
	"context"
	"log/slog"
	"sync"
	"time"
)

// presence batches user_presence_cell writes: callers record, a background
// task flushes at most once per second in one statement (section 7.5).
type presence struct {
	mu      sync.Mutex
	pending map[string]uint64
}

func (p *presence) record(userID string, h3r7 uint64) {
	if userID == "" || h3r7 == 0 {
		return
	}
	p.mu.Lock()
	if p.pending == nil {
		p.pending = map[string]uint64{}
	}
	p.pending[userID] = h3r7
	p.mu.Unlock()
}

func (p *presence) take() map[string]uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.pending
	p.pending = nil
	return out
}

func (s *Store) runPresence(ctx context.Context, log *slog.Logger) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	flush := func(ctx context.Context) {
		batch := s.pres.take()
		if len(batch) == 0 {
			return
		}
		wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		if err := s.b.WritePresence(wctx, batch); err != nil {
			log.Warn("presence write failed", "rows", len(batch), "err", err)
		}
	}
	for {
		select {
		case <-ctx.Done():
			// Final flush for disconnects recorded during shutdown.
			fctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			flush(fctx)
			cancel()
			return
		case <-t.C:
			flush(ctx)
		}
	}
}
