package store

import (
	"context"
	"sync"
)

// memBackend is the dev stand-in for Postgres. Unknown users get a profile on
// first sight, with uids assigned in order.
type memBackend struct {
	mu       sync.Mutex
	nextUID  uint64
	profiles map[string]*Profile
	settings map[string]Settings
	friends  map[string]map[string]bool
	teams    map[string]map[string]bool // user -> teammates
	blocks   map[string]map[string]bool // blocker -> blocked
	presence map[string]uint64
}

func newMem() *memBackend {
	return &memBackend{
		nextUID:  1,
		profiles: map[string]*Profile{},
		settings: map[string]Settings{},
		friends:  map[string]map[string]bool{},
		teams:    map[string]map[string]bool{},
		blocks:   map[string]map[string]bool{},
		presence: map[string]uint64{},
	}
}

func (m *memBackend) Close() {}

func (m *memBackend) profileLocked(userID string) *Profile {
	p, ok := m.profiles[userID]
	if !ok {
		short := userID
		if len(short) > 8 {
			short = short[:8]
		}
		p = &Profile{UserID: userID, UID: m.nextUID, DisplayName: "dev_" + short, MarkerIcon: "coupe"}
		m.nextUID++
		m.profiles[userID] = p
	}
	return p
}

func (m *memBackend) Profile(_ context.Context, userID string) (Profile, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return *m.profileLocked(userID), nil
}

func (m *memBackend) Settings(_ context.Context, userID string) (Settings, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.settings[userID]; ok {
		return s, nil
	}
	return DefaultSettings(), nil
}

func (m *memBackend) PutSettings(_ context.Context, userID string, s Settings) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.settings[userID] = s
	return nil
}

func (m *memBackend) blockedEitherLocked(a, b string) bool {
	return m.blocks[a][b] || m.blocks[b][a]
}

func (m *memBackend) Relations(_ context.Context, userID string) (Relations, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var r Relations
	for other := range m.friends[userID] {
		if !m.blockedEitherLocked(userID, other) && len(r.Friends) < MaxRelations {
			r.Friends = append(r.Friends, m.profileLocked(other).UID)
		}
	}
	for other := range m.teams[userID] {
		if !m.blockedEitherLocked(userID, other) && len(r.Teammates) < MaxRelations {
			r.Teammates = append(r.Teammates, m.profileLocked(other).UID)
		}
	}
	seen := map[string]bool{}
	for other := range m.blocks[userID] {
		seen[other] = true
	}
	for blocker, set := range m.blocks {
		if set[userID] {
			seen[blocker] = true
		}
	}
	for other := range seen {
		r.Blocked = append(r.Blocked, m.profileLocked(other).UID)
	}
	return r, nil
}

func (m *memBackend) WritePresence(_ context.Context, cells map[string]uint64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, h := range cells {
		m.presence[id] = h
	}
	return nil
}

// Dev seeding, used by the /dev endpoints.

func link(m map[string]map[string]bool, a, b string) {
	if m[a] == nil {
		m[a] = map[string]bool{}
	}
	m[a][b] = true
}

func (m *memBackend) setProfile(p Profile) Profile {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur := m.profileLocked(p.UserID)
	if p.DisplayName != "" {
		cur.DisplayName = p.DisplayName
	}
	if p.MarkerIcon != "" {
		cur.MarkerIcon = p.MarkerIcon
	}
	cur.MarkerTrail = p.MarkerTrail
	cur.PaintRGB = p.PaintRGB
	cur.CarLabel = p.CarLabel
	return *cur
}

func (m *memBackend) addFriends(a, b string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.profileLocked(a)
	m.profileLocked(b)
	link(m.friends, a, b)
	link(m.friends, b, a)
}

func (m *memBackend) addTeam(members []string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, a := range members {
		m.profileLocked(a)
		for _, b := range members {
			if a != b {
				link(m.teams, a, b)
			}
		}
	}
}

func (m *memBackend) addBlock(blocker, blocked string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.profileLocked(blocker)
	m.profileLocked(blocked)
	link(m.blocks, blocker, blocked)
}
