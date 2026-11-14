package ws

import (
	"context"
	"time"

	"waypoints/server/internal/wire"
)

// suspensionSweep is how often open connections are re-checked against
// profiles.suspended_at (SAFE-7). Connect-time checks alone would leave a
// suspended account connected until its next token refresh.
const suspensionSweep = 30 * time.Second

// sweepSuspended closes, with reason "suspended", every open connection whose
// account has been suspended since it connected. One query per sweep covers
// every distinct user on this node.
func (s *Server) sweepSuspended(ctx context.Context) {
	t := time.NewTicker(suspensionSweep)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		s.closeSuspended(ctx)
	}
}

func (s *Server) closeSuspended(ctx context.Context) {
	s.mu.RLock()
	seen := make(map[string]struct{}, len(s.conns))
	ids := make([]string, 0, len(s.conns))
	for c := range s.conns {
		if _, ok := seen[c.userID]; !ok && c.userID != "" {
			seen[c.userID] = struct{}{}
			ids = append(ids, c.userID)
		}
	}
	s.mu.RUnlock()
	if len(ids) == 0 {
		return
	}
	suspended := s.auth.SuspendedAmong(ctx, ids)
	if len(suspended) == 0 {
		return
	}
	drop := make(map[string]struct{}, len(suspended))
	for _, id := range suspended {
		drop[id] = struct{}{}
	}
	s.mu.RLock()
	var cs []*conn
	for c := range s.conns {
		if _, ok := drop[c.userID]; ok {
			cs = append(cs, c)
		}
	}
	s.mu.RUnlock()
	for _, c := range cs {
		go c.closeWith(wire.Error_UNAUTHORIZED, "suspended", closeUnauthorized)
	}
}
