package api

import (
	"context"
	"net/http"
	"time"
	_ "time/tzdata" // recurring meets compute the next date in the host's zone

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/push"
	"waypoints/server/internal/wire"
)

// registerMeets mounts the meet endpoints and the two meet sweeps.
func (s *Service) registerMeets(a *app.App) {
	a.Mux.HandleFunc("POST /v1/meets", Authed(s.auth, s.createMeet))
	a.Mux.HandleFunc("PATCH /v1/meets/{id}", Authed(s.auth, s.updateMeet))
	a.Mux.HandleFunc("DELETE /v1/meets/{id}", Authed(s.auth, s.cancelMeet))
	a.Go("meet-checkins", s.runCheckins)
	a.Go("meet-series", s.runSeries)
}

// runCheckins records a check-in for every Going RSVP within 200 m of a meet while it is on.
// It reads positions only from this node's memory and writes no coordinates.
func (s *Service) runCheckins(ctx context.Context) {
	t := time.NewTicker(2 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		pool := s.store.Pool()
		if pool == nil {
			continue
		}
		rows, err := pool.Query(ctx, `select m.id::text, st_y(m.geom::geometry), st_x(m.geom::geometry), r.user_id::text
			from public.meets m join public.meet_rsvps r on r.meet_id = m.id
			where m.cancelled_at is null and m.starts_at <= now() and m.ends_at > now() and r.status = 'going'
			  and not exists (select 1 from public.meet_checkins c where c.meet_id = m.id and c.user_id = r.user_id)`)
		if err != nil {
			continue
		}
		type hit struct{ meet, user string }
		var hits []hit
		for rows.Next() {
			var meet, user string
			var lat, lng float64
			if rows.Scan(&meet, &lat, &lng, &user) != nil {
				continue
			}
			if la, ln, ok := s.ws.LastFix(user); ok && geo.DistanceM(la, ln, geo.E7(lat), geo.E7(lng)) <= 200 {
				hits = append(hits, hit{meet, user})
			}
		}
		rows.Close()
		for _, h := range hits {
			_, _ = pool.Exec(ctx, `insert into public.meet_checkins (meet_id, user_id) values ($1, $2) on conflict do nothing`, h.meet, h.user)
		}
	}
}

// MARK: recurring meets (MEET-12)

var recurrences = map[string]bool{"weekly": true, "biweekly": true, "monthly": true}

// nextStart is the start of the occurrence after t: a week or two later, or the same
// weekday of the same week of next month (the last such weekday when that month has no fifth).
// Wall-clock time is kept in loc, so a series does not drift an hour across daylight saving.
func nextStart(t time.Time, rule string, loc *time.Location) time.Time {
	t = t.In(loc)
	switch rule {
	case "weekly":
		return t.AddDate(0, 0, 7)
	case "biweekly":
		return t.AddDate(0, 0, 14)
	}
	nth := (t.Day() - 1) / 7
	first := time.Date(t.Year(), t.Month()+1, 1, t.Hour(), t.Minute(), t.Second(), 0, loc)
	offset := (int(t.Weekday()) - int(first.Weekday()) + 7) % 7
	d := first.AddDate(0, 0, offset+7*nth)
	if d.Month() != first.Month() {
		d = d.AddDate(0, 0, -7)
	}
	return d
}

// runSeries creates the next occurrence of every recurring meet that has ended and has no
// later occurrence yet. RSVPs do not carry over; people who checked in at the one that ended
// are told once.
func (s *Service) runSeries(ctx context.Context) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		pool := s.store.Pool()
		if pool == nil {
			continue
		}
		rows, err := pool.Query(ctx, `select `+meetCols+`, coalesce(time_zone, '') from public.meets m
			where m.recurrence is not null and m.ends_at <= now()
			  and not exists (select 1 from public.meets n where n.series_id = m.series_id and n.starts_at > m.starts_at)
			limit 100`)
		if err != nil {
			continue
		}
		type ended struct {
			m  meetJSON
			tz string
		}
		var due []ended
		for rows.Next() {
			var e ended
			var err error
			e.m, err = scanMeetWith(rows, &e.tz)
			if err == nil && e.m.Recurrence != nil {
				due = append(due, e)
			}
		}
		rows.Close()
		for _, e := range due {
			s.spawnNext(ctx, pool, e.m, e.tz)
		}
	}
}

func (s *Service) spawnNext(ctx context.Context, pool *pgxpool.Pool, old meetJSON, tz string) {
	loc, err := time.LoadLocation(tz)
	if tz == "" || err != nil {
		loc = time.UTC
	}
	length := old.EndsAt.Sub(old.StartsAt)
	start := nextStart(old.StartsAt, *old.Recurrence, loc)
	for !start.Add(length).After(time.Now()) { // the gateway was down through whole occurrences
		start = nextStart(start, *old.Recurrence, loc)
	}
	m, err := scanMeet(pool.QueryRow(ctx, `insert into public.meets
		(host_id, title, kind, geom, h3_r7, place_name, starts_at, ends_at, details, visibility, team_id,
		 recurrence, series_id, time_zone, dest_lat, dest_lng, dest_name)
		select host_id, title, kind, geom, h3_r7, place_name, $2, $3, details, visibility, team_id,
		       recurrence, series_id, time_zone, dest_lat, dest_lng, dest_name
		from public.meets where id = $1
		on conflict (series_id, starts_at) do nothing
		returning `+meetCols, old.ID, start, start.Add(length)))
	if err != nil {
		return // pgx.ErrNoRows: another node made it first
	}
	if m.Visibility == "public" {
		s.publishMeet(m, wire.MapEvent_UPSERT)
	}
	if s.push == nil {
		return
	}
	rows, err := pool.Query(ctx, `select user_id::text from public.meet_checkins where meet_id = $1`, old.ID)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			ids = append(ids, id)
		}
	}
	rows.Close()
	go s.push.Send(context.WithoutCancel(ctx), ids, push.Note{Kind: push.MeetReminders, Title: m.Title,
		Body: "The next one is " + start.In(loc).Format("Mon Jan 2, 3:04 PM") + ".", URL: "waypoints://meet/" + m.ID,
		ActorID: m.HostID, Dedupe: "meet-next:" + m.ID})
}

// MARK: meets

type destJSON struct {
	Lat  float64 `json:"lat"`
	Lng  float64 `json:"lng"`
	Name string  `json:"name"`
}

type meetBody struct {
	Title       string    `json:"title"`
	Kind        string    `json:"kind"`
	Lat         float64   `json:"lat"`
	Lng         float64   `json:"lng"`
	PlaceName   string    `json:"place_name"`
	StartsAt    time.Time `json:"starts_at"`
	EndsAt      time.Time `json:"ends_at"`
	Details     string    `json:"details"`
	Visibility  string    `json:"visibility"`
	TeamID      *string   `json:"team_id"`
	Recurrence  *string   `json:"recurrence"`  // weekly, biweekly, monthly; null for a one-off
	TimeZone    *string   `json:"time_zone"`   // IANA name the series repeats in
	Destination *destJSON `json:"destination"` // where a cruise rolls out to
}

func (b meetBody) validate() string {
	switch {
	case n(b.Title) < 1 || n(b.Title) > 50:
		return "title"
	case !map[string]bool{"meet": true, "cruise": true, "hangout": true, "track_day": true, "show": true}[b.Kind]:
		return "kind"
	case !geo.Valid(geo.E7(b.Lat), geo.E7(b.Lng)):
		return "location"
	case n(b.PlaceName) > 80, n(b.Details) > 500:
		return "text"
	case !b.EndsAt.After(b.StartsAt):
		return "ends_at"
	case !map[string]bool{"public": true, "friends": true, "team": true}[b.Visibility]:
		return "visibility"
	case (b.Visibility == "team") != (b.TeamID != nil):
		return "team_id"
	case b.Recurrence != nil && !recurrences[*b.Recurrence]:
		return "recurrence"
	case b.TimeZone != nil && n(*b.TimeZone) > 64:
		return "time_zone"
	case b.Destination != nil && (!geo.Valid(geo.E7(b.Destination.Lat), geo.E7(b.Destination.Lng)) || n(b.Destination.Name) > 80):
		return "destination"
	}
	return ""
}

// destArgs splits the destination into nullable columns.
func (b meetBody) destArgs() (lat, lng *float64, name *string) {
	if d := b.Destination; d != nil {
		return &d.Lat, &d.Lng, &d.Name
	}
	return nil, nil, nil
}

func n(s string) int { return len([]rune(s)) }

type meetJSON struct {
	ID          string     `json:"id"`
	HostID      string     `json:"host_id"`
	Title       string     `json:"title"`
	Kind        string     `json:"kind"`
	Lat         float64    `json:"lat"`
	Lng         float64    `json:"lng"`
	PlaceName   string     `json:"place_name"`
	StartsAt    time.Time  `json:"starts_at"`
	EndsAt      time.Time  `json:"ends_at"`
	Details     string     `json:"details"`
	Visibility  string     `json:"visibility"`
	TeamID      *string    `json:"team_id"`
	CancelledAt *time.Time `json:"cancelled_at"`
	CreatedAt   time.Time  `json:"created_at"`
	Recurrence  *string    `json:"recurrence"`
	SeriesID    *string    `json:"series_id"`
	Destination *destJSON  `json:"destination"`
}

const meetCols = `id::text, host_id::text, title, kind::text, st_y(geom::geometry), st_x(geom::geometry),
	coalesce(place_name, ''), starts_at, ends_at, coalesce(details, ''), visibility::text, team_id::text, cancelled_at, created_at,
	recurrence, series_id::text, dest_lat, dest_lng, coalesce(dest_name, '')`

func scanMeet(row pgx.Row) (meetJSON, error) { return scanMeetWith(row) }

// scanMeetWith scans meetCols followed by any extra columns.
func scanMeetWith(row pgx.Row, extra ...any) (meetJSON, error) {
	var m meetJSON
	var dLat, dLng *float64
	var dName string
	dest := []any{&m.ID, &m.HostID, &m.Title, &m.Kind, &m.Lat, &m.Lng, &m.PlaceName, &m.StartsAt, &m.EndsAt,
		&m.Details, &m.Visibility, &m.TeamID, &m.CancelledAt, &m.CreatedAt, &m.Recurrence, &m.SeriesID, &dLat, &dLng, &dName}
	err := row.Scan(append(dest, extra...)...)
	if dLat != nil && dLng != nil {
		m.Destination = &destJSON{Lat: *dLat, Lng: *dLng, Name: dName}
	}
	return m, err
}

func (s *Service) publishMeet(m meetJSON, op wire.MapEvent_Op) {
	s.ws.PublishMapEvent(&wire.MapEvent{Kind: wire.MapEvent_MEET, Id: m.ID, Op: op,
		LatE7: geo.E7(m.Lat), LngE7: geo.E7(m.Lng), Subtype: m.Kind, Title: m.Title})
}

func (s *Service) canHostForTeam(ctx context.Context, pool *pgxpool.Pool, userID, teamID string) bool {
	var ok bool
	_ = pool.QueryRow(ctx, `select exists (
		select 1 from public.teams t where t.id = $2 and t.owner_id = $1
		union all
		select 1 from public.team_members m join public.team_roles r on r.id = m.role_id
		where m.team_id = $2 and m.user_id = $1 and (r.permissions & 32) <> 0)`, userID, teamID).Scan(&ok)
	return ok
}

func (s *Service) createMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b meetBody
	if Decode(r, &b) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if f := b.validate(); f != "" {
		Error(w, http.StatusBadRequest, f)
		return
	}
	pool := Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	if b.TeamID != nil && !s.canHostForTeam(ctx, pool, c.UserID, *b.TeamID) {
		Error(w, http.StatusForbidden, "forbidden")
		return
	}
	var today int
	_ = pool.QueryRow(ctx, `select count(*) from public.meets where host_id = $1 and created_at > now() - interval '1 day'
		and (series_id is null or not exists (select 1 from public.meets p where p.series_id = meets.series_id and p.starts_at < meets.starts_at))`,
		c.UserID).Scan(&today)
	if today >= 3 {
		Error(w, http.StatusTooManyRequests, "daily meet limit")
		return
	}
	h3 := int64(geo.Cell(geo.E7(b.Lat), geo.E7(b.Lng), geo.ResCell))
	dLat, dLng, dName := b.destArgs()
	m, err := scanMeet(pool.QueryRow(ctx, `insert into public.meets
		(host_id, title, kind, geom, h3_r7, place_name, starts_at, ends_at, details, visibility, team_id,
		 recurrence, series_id, time_zone, dest_lat, dest_lng, dest_name)
		values ($1, $2, $3::public.meet_kind, st_setsrid(st_makepoint($4, $5), 4326)::geography, $6, $7, $8, $9, $10,
		        $11::public.meet_visibility, $12,
		        $13::text, case when $13::text is null then null else gen_random_uuid() end, $14, $15, $16, $17)
		returning `+meetCols, c.UserID, b.Title, b.Kind, b.Lng, b.Lat, h3, b.PlaceName, b.StartsAt, b.EndsAt, b.Details,
		b.Visibility, b.TeamID, b.Recurrence, b.TimeZone, dLat, dLng, dName))
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not save meet")
		return
	}
	if b.Visibility == "public" {
		s.publishMeet(m, wire.MapEvent_UPSERT)
		if s.push != nil {
			go s.push.MeetNearby(context.WithoutCancel(ctx), c.UserID, m.ID, m.Title, geo.E7(m.Lat), geo.E7(m.Lng))
		}
	}
	JSON(w, http.StatusCreated, m)
}

func (s *Service) hostMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) (*pgxpool.Pool, meetJSON, bool) {
	pool := Pool(w, s.store)
	if pool == nil {
		return nil, meetJSON{}, false
	}
	m, err := scanMeet(pool.QueryRow(r.Context(), `select `+meetCols+` from public.meets where id = $1`, r.PathValue("id")))
	if err != nil {
		Error(w, http.StatusNotFound, "not found")
		return nil, m, false
	}
	if m.HostID != c.UserID {
		Error(w, http.StatusForbidden, "forbidden")
		return nil, m, false
	}
	return pool, m, true
}

func (s *Service) updateMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b meetBody
	if Decode(r, &b) != nil {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if f := b.validate(); f != "" {
		Error(w, http.StatusBadRequest, f)
		return
	}
	pool, old, ok := s.hostMeet(w, r, c)
	if !ok {
		return
	}
	ctx := r.Context()
	h3 := int64(geo.Cell(geo.E7(b.Lat), geo.E7(b.Lng), geo.ResCell))
	dLat, dLng, dName := b.destArgs()
	m, err := scanMeet(pool.QueryRow(ctx, `update public.meets set title = $2, kind = $3::public.meet_kind,
		geom = st_setsrid(st_makepoint($4, $5), 4326)::geography, h3_r7 = $6, place_name = $7, starts_at = $8, ends_at = $9,
		details = $10, visibility = $11::public.meet_visibility, team_id = $12,
		recurrence = $13::text,
		series_id = coalesce(series_id, case when $13::text is null then null else gen_random_uuid() end),
		time_zone = coalesce($14, time_zone), dest_lat = $15, dest_lng = $16, dest_name = $17
		where id = $1 returning `+meetCols, old.ID, b.Title, b.Kind, b.Lng, b.Lat, h3, b.PlaceName, b.StartsAt, b.EndsAt,
		b.Details, b.Visibility, b.TeamID, b.Recurrence, b.TimeZone, dLat, dLng, dName))
	if err != nil {
		Error(w, http.StatusInternalServerError, "could not save meet")
		return
	}
	if m.Visibility == "public" {
		s.publishMeet(m, wire.MapEvent_UPSERT)
	} else if old.Visibility == "public" {
		s.publishMeet(old, wire.MapEvent_REMOVE)
	}
	if s.push != nil && !m.StartsAt.Equal(old.StartsAt) {
		go s.push.MeetChanged(context.WithoutCancel(ctx), m.ID, m.Title, "New time: "+m.StartsAt.Format("Mon 3:04 PM"))
	}
	JSON(w, http.StatusOK, m)
}

// cancelMeet cancels one occurrence. With scope "following" (body {"scope"} or ?scope=) it
// also cancels every later occurrence of the series and ends the series.
func (s *Service) cancelMeet(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b struct {
		Scope string `json:"scope"`
	}
	_ = Decode(r, &b) // the body is optional
	following := b.Scope == "following" || r.URL.Query().Get("scope") == "following"
	pool, m, ok := s.hostMeet(w, r, c)
	if !ok {
		return
	}
	ctx := r.Context()
	cancelled := []meetJSON{m}
	if following && m.SeriesID != nil {
		rows, err := pool.Query(ctx, `update public.meets set cancelled_at = coalesce(cancelled_at, now()), recurrence = null
			where series_id = $1 and starts_at >= $2 returning `+meetCols, *m.SeriesID, m.StartsAt)
		if err != nil {
			Error(w, http.StatusInternalServerError, "could not cancel")
			return
		}
		cancelled = cancelled[:0]
		for rows.Next() {
			if x, err := scanMeetWith(rows); err == nil {
				cancelled = append(cancelled, x)
			}
		}
		rows.Close()
		if rows.Err() != nil {
			Error(w, http.StatusInternalServerError, "could not cancel")
			return
		}
	} else if _, err := pool.Exec(ctx, `update public.meets set cancelled_at = now() where id = $1`, m.ID); err != nil {
		Error(w, http.StatusInternalServerError, "could not cancel")
		return
	}
	for _, x := range cancelled {
		s.publishMeet(x, wire.MapEvent_REMOVE)
		// Only occurrences cancelled by this request; earlier cancellations were already told.
		fresh := x.CancelledAt == nil || time.Since(*x.CancelledAt) < time.Minute
		if s.push != nil && fresh {
			go s.push.MeetChanged(context.WithoutCancel(ctx), x.ID, x.Title, "Cancelled by the host.")
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
