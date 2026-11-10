package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// pgBackend runs against Supabase Postgres with a role that bypasses RLS
// (the service role or the postgres user). Every query is parameterized.
type pgBackend struct{ pool *pgxpool.Pool }

func newPG(url string) (*pgBackend, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, err
	}
	cfg.MaxConns = 8
	cfg.MaxConnIdleTime = 5 * time.Minute
	// Supabase's pooler (pgbouncer in transaction mode) does not support
	// prepared statements across transactions; the simple protocol works with
	// both the pooler and direct connections.
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return nil, err
	}
	return &pgBackend{pool: pool}, nil
}

func (p *pgBackend) ping(ctx context.Context) error { return p.pool.Ping(ctx) }

func (p *pgBackend) Close() { p.pool.Close() }

func (p *pgBackend) Profile(ctx context.Context, userID string) (Profile, error) {
	const q = `
select p.uid, p.display_name, p.marker_icon, coalesce(p.marker_trail, ''),
       coalesce(c.color_hex, ''),
       coalesce(c.year::text || ' ' || c.make || ' ' || c.model, '')
from public.profiles p
left join public.cars c on c.id = p.primary_car_id
where p.user_id = $1`
	pr := Profile{UserID: userID}
	var uid int64
	var hex string
	err := p.pool.QueryRow(ctx, q, userID).Scan(&uid, &pr.DisplayName, &pr.MarkerIcon, &pr.MarkerTrail, &hex, &pr.CarLabel)
	if errors.Is(err, pgx.ErrNoRows) {
		return Profile{}, ErrNotFound
	}
	if err != nil {
		return Profile{}, wrap("profile", err)
	}
	pr.UID = uint64(uid)
	pr.PaintRGB = parseHex(hex)
	return pr, nil
}

func (p *pgBackend) Settings(ctx context.Context, userID string) (Settings, error) {
	const q = `
select friends_level::text, team_level::text, nearby_level::text, ghost_until,
       notify_meets_nearby, notify_radius_km
from public.privacy_settings where user_id = $1`
	var s Settings
	var f, t, n string
	var ghost *time.Time
	err := p.pool.QueryRow(ctx, q, userID).Scan(&f, &t, &n, &ghost, &s.NotifyMeetsNearby, &s.NotifyRadiusKm)
	if errors.Is(err, pgx.ErrNoRows) {
		return DefaultSettings(), nil
	}
	if err != nil {
		return Settings{}, wrap("settings", err)
	}
	s.Friends, s.Team, s.Nearby = Level(f), Level(t), Level(n)
	if ghost != nil {
		s.GhostUntil = *ghost
	}
	return s, nil
}

func (p *pgBackend) PutSettings(ctx context.Context, userID string, s Settings) error {
	const q = `
insert into public.privacy_settings
  (user_id, friends_level, team_level, nearby_level, ghost_until, notify_meets_nearby, notify_radius_km)
values ($1, $2::public.share_level, $3::public.share_level, $4::public.share_level, $5, $6, $7)
on conflict (user_id) do update set
  friends_level = excluded.friends_level, team_level = excluded.team_level,
  nearby_level = excluded.nearby_level, ghost_until = excluded.ghost_until,
  notify_meets_nearby = excluded.notify_meets_nearby, notify_radius_km = excluded.notify_radius_km`
	var ghost *time.Time
	if !s.GhostUntil.IsZero() {
		g := s.GhostUntil
		ghost = &g
	}
	_, err := p.pool.Exec(ctx, q, userID, string(s.Friends), string(s.Team), string(s.Nearby), ghost, s.NotifyMeetsNearby, s.NotifyRadiusKm)
	return wrap("put settings", err)
}

func (p *pgBackend) Relations(ctx context.Context, userID string) (Relations, error) {
	const blocked = `
select p.uid from public.blocks b
join public.profiles p on p.user_id = case when b.blocker_id = $1 then b.blocked_id else b.blocker_id end
where b.blocker_id = $1 or b.blocked_id = $1`
	const friends = `
select p.uid from public.friendships f
join public.profiles p on p.user_id = case when f.requester_id = $1 then f.addressee_id else f.requester_id end
where (f.requester_id = $1 or f.addressee_id = $1) and f.status = 'accepted'
  and not exists (select 1 from public.blocks b
                  where (b.blocker_id = $1 and b.blocked_id = p.user_id)
                     or (b.blocker_id = p.user_id and b.blocked_id = $1))
limit $2`
	const teammates = `
select distinct p.uid from public.team_members a
join public.team_members m on m.team_id = a.team_id and m.user_id <> a.user_id
join public.profiles p on p.user_id = m.user_id
where a.user_id = $1
  and not exists (select 1 from public.blocks b
                  where (b.blocker_id = $1 and b.blocked_id = p.user_id)
                     or (b.blocker_id = p.user_id and b.blocked_id = $1))
limit $2`
	var r Relations
	var err error
	if r.Blocked, err = p.uids(ctx, blocked, userID); err != nil {
		return Relations{}, wrap("blocks", err)
	}
	if r.Friends, err = p.uids(ctx, friends, userID, MaxRelations); err != nil {
		return Relations{}, wrap("friends", err)
	}
	if r.Teammates, err = p.uids(ctx, teammates, userID, MaxRelations); err != nil {
		return Relations{}, wrap("teammates", err)
	}
	return r, nil
}

func (p *pgBackend) uids(ctx context.Context, q string, args ...any) ([]uint64, error) {
	rows, err := p.pool.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (uint64, error) {
		var v int64
		err := row.Scan(&v)
		return uint64(v), err
	})
	return out, err
}

// WritePresence upserts many users' cells in one statement.
func (p *pgBackend) WritePresence(ctx context.Context, cells map[string]uint64) error {
	ids := make([]string, 0, len(cells))
	hs := make([]int64, 0, len(cells))
	for id, h := range cells {
		ids = append(ids, id)
		hs = append(hs, int64(h))
	}
	const q = `
insert into public.user_presence_cell (user_id, h3_r7, updated_at)
select u, h, now() from unnest($1::uuid[], $2::bigint[]) as t(u, h)
where exists (select 1 from public.profiles where user_id = t.u)
on conflict (user_id) do update set h3_r7 = excluded.h3_r7, updated_at = now()`
	_, err := p.pool.Exec(ctx, q, ids, hs)
	return wrap("presence", err)
}

func parseHex(s string) uint32 {
	s = strings.TrimPrefix(s, "#")
	if len(s) != 6 {
		return 0
	}
	v, err := strconv.ParseUint(s, 16, 32)
	if err != nil {
		return 0
	}
	return uint32(v)
}
