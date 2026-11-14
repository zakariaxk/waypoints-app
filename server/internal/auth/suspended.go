package auth

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"waypoints/server/internal/store"
)

// ErrSuspended is returned for a valid token whose account is suspended
// (SAFE-7). It wraps ErrUnauthorized, so callers that only check for that
// still refuse the connection.
var ErrSuspended = fmt.Errorf("%w: account suspended", ErrUnauthorized)

// suspensionTTL bounds how long a suspension takes to reach the gateway, and
// how often one user's status is read from Postgres.
const suspensionTTL = time.Minute

// suspensions answers "is this account suspended" from profiles.suspended_at,
// cached per user. Without a database (memory mode, bench) nobody is.
// Database errors fail open: a Postgres outage must not lock everyone out.
type suspensions struct {
	st  *store.Store
	log *slog.Logger

	mu    sync.Mutex
	cache map[string]suspensionEntry
}

type suspensionEntry struct {
	suspended bool
	checked   time.Time
}

func newSuspensions(st *store.Store, log *slog.Logger) *suspensions {
	return &suspensions{st: st, log: log, cache: map[string]suspensionEntry{}}
}

func (s *suspensions) suspended(ctx context.Context, userID string) bool {
	if s == nil || s.st == nil {
		return false
	}
	now := time.Now()
	s.mu.Lock()
	e, ok := s.cache[userID]
	s.mu.Unlock()
	if ok && now.Sub(e.checked) < suspensionTTL {
		return e.suspended
	}

	pool := s.st.Pool()
	if pool == nil || !looksLikeUUID(userID) {
		return false
	}
	qctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	var suspended bool
	err := pool.QueryRow(qctx, `select exists (
		select 1 from public.profiles where user_id = $1::uuid and suspended_at is not null)`,
		userID).Scan(&suspended)
	if err != nil {
		s.log.Warn("suspension check failed", "err", err)
		if ok {
			return e.suspended
		}
		return false
	}

	s.mu.Lock()
	if len(s.cache) > 50_000 {
		for k, v := range s.cache {
			if now.Sub(v.checked) >= suspensionTTL {
				delete(s.cache, k)
			}
		}
	}
	s.cache[userID] = suspensionEntry{suspended: suspended, checked: now}
	s.mu.Unlock()
	return suspended
}

func looksLikeUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
	}
	return true
}
