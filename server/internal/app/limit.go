package app

import (
	"sync"
	"time"
)

// Limiter is a per-key sliding-window rate limiter for in-process abuse
// control. It is deliberately simple: one mutex, a map of key to recent
// timestamps, and a sweep at most once a minute so keys idle longer than the
// window are evicted and the map cannot grow without bound. Limits are per
// node; where a limit must hold across nodes the database enforces it instead
// (see reports and help requests).
type Limiter struct {
	mu        sync.Mutex
	n         int
	window    time.Duration
	hits      map[string][]time.Time
	lastSweep time.Time
}

// NewLimiter allows n events per window per key.
func NewLimiter(n int, window time.Duration) *Limiter {
	return &Limiter{n: n, window: window, hits: map[string][]time.Time{}}
}

// Allow records an event for key and reports whether it is within the limit.
func (l *Limiter) Allow(key string) bool {
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	if now.Sub(l.lastSweep) > time.Minute {
		l.sweep(now)
	}
	h := l.hits[key][:0]
	for _, t := range l.hits[key] {
		if now.Sub(t) < l.window {
			h = append(h, t)
		}
	}
	if len(h) >= l.n {
		l.hits[key] = h
		return false
	}
	l.hits[key] = append(h, now)
	return true
}

// sweep drops keys whose newest event is older than the window.
func (l *Limiter) sweep(now time.Time) {
	l.lastSweep = now
	for k, h := range l.hits {
		if len(h) == 0 || now.Sub(h[len(h)-1]) >= l.window {
			delete(l.hits, k)
		}
	}
}
