// Package store holds the gateway's Postgres queries: profiles, privacy
// settings, friendships, teammates, blocks, and the presence cell.
//
// Nothing here is on the realtime path. Queries run at connect (Hello), on
// PUT /v1/privacy, and in the batched presence writer. Callers cache results
// in memory.
//
// With no DATABASE_URL (or, in dev, an unreachable database) the store runs on
// an in-memory backend so the gateway works locally without Supabase. In that
// mode /dev/... endpoints seed profiles and relations (see dev.go).
package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Level is a sharing level for one audience (section 2.5).
type Level string

const (
	Precise Level = "precise"
	Approx  Level = "approx"
	Hidden  Level = "hidden"
)

// Valid reports whether l is one of the three levels.
func (l Level) Valid() bool { return l == Precise || l == Approx || l == Hidden }

// Rank orders levels: hidden < approx < precise.
func (l Level) Rank() int {
	switch l {
	case Precise:
		return 2
	case Approx:
		return 1
	}
	return 0
}

// Profile is what the gateway needs about a user to publish them.
type Profile struct {
	UserID      string // auth.users id (uuid text)
	UID         uint64 // profiles.uid, the wire id
	DisplayName string
	MarkerIcon  string
	MarkerTrail string
	PaintRGB    uint32 // from the primary car's color_hex; 0 when unknown
	CarLabel    string // "2019 Ford Mustang GT"; empty when no primary car
}

// Settings mirrors privacy_settings.
type Settings struct {
	Friends           Level
	Team              Level
	Nearby            Level
	GhostUntil        time.Time // zero when not ghosting
	NotifyMeetsNearby bool
	NotifyRadiusKm    int
}

// DefaultSettings are the section 2.5 defaults, used when no row exists.
func DefaultSettings() Settings {
	return Settings{Friends: Precise, Team: Approx, Nearby: Hidden, NotifyRadiusKm: 15}
}

// Validate checks the column constraints.
func (s Settings) Validate() error {
	if !s.Friends.Valid() || !s.Team.Valid() || !s.Nearby.Valid() {
		return errors.New("levels must be precise, approx, or hidden")
	}
	if s.Nearby == Precise {
		return errors.New("nearby_level cannot be precise")
	}
	if s.NotifyRadiusKm < 1 || s.NotifyRadiusKm > 100 {
		return errors.New("notify_radius_km must be between 1 and 100")
	}
	return nil
}

// Relations are a user's accepted friends, teammates, and blocks in either
// direction, as wire uids. Friends and teammates exclude blocked users.
type Relations struct {
	Friends   []uint64
	Teammates []uint64
	Blocked   []uint64
}

// MaxRelations caps friends and teammates loaded per user (section 7.3).
const MaxRelations = 1000

// ErrNotFound means the user has no profile row.
var ErrNotFound = errors.New("store: not found")

type backend interface {
	Profile(ctx context.Context, userID string) (Profile, error)
	Settings(ctx context.Context, userID string) (Settings, error)
	PutSettings(ctx context.Context, userID string, s Settings) error
	Relations(ctx context.Context, userID string) (Relations, error)
	WritePresence(ctx context.Context, cells map[string]uint64) error
	Close()
}

// Store is the gateway's view of Postgres. Its backend is chosen before the
// gateway starts serving and never changes afterwards.
type Store struct {
	b      backend
	mem    *memBackend // non-nil in memory mode
	pres   *presence
	reason string
}

// InMemory reports whether the store runs without a database.
func (s *Store) InMemory() bool { return s.mem != nil }

// Profile loads a user's profile. In memory mode unknown users get one.
func (s *Store) Profile(ctx context.Context, userID string) (Profile, error) {
	return s.b.Profile(ctx, userID)
}

// Settings loads privacy settings, falling back to defaults when no row exists.
func (s *Store) Settings(ctx context.Context, userID string) (Settings, error) {
	return s.b.Settings(ctx, userID)
}

// PutSettings writes privacy settings. Only the gateway writes this table.
func (s *Store) PutSettings(ctx context.Context, userID string, st Settings) error {
	if err := st.Validate(); err != nil {
		return err
	}
	return s.b.PutSettings(ctx, userID, st)
}

// Relations loads friends, teammates, and blocks.
func (s *Store) Relations(ctx context.Context, userID string) (Relations, error) {
	return s.b.Relations(ctx, userID)
}

// RecordPresence queues the user's resolution 7 cell for the batched writer
// (section 7.5). It never blocks and never touches the database itself.
func (s *Store) RecordPresence(userID string, h3r7 uint64) {
	s.pres.record(userID, h3r7)
}

func wrap(op string, err error) error {
	if err == nil || errors.Is(err, ErrNotFound) {
		return err
	}
	return fmt.Errorf("store %s: %w", op, err)
}

// Pool returns the Postgres pool, or nil when the store runs in memory. Packages
// with their own queries (api, convoy, push, voice) use it and degrade to 503
// without it.
func (s *Store) Pool() *pgxpool.Pool {
	if pg, ok := s.b.(*pgBackend); ok {
		return pg.pool
	}
	return nil
}
