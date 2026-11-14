// Package eta serves POST /v1/eta (PRD NAV-15): while navigating, a driver sends chosen
// friends one notice with the destination name and the arrival time. No position is sent or
// stored. When the destination is a meet the driver is Going to, the RSVP is marked "on the
// way" until shortly after the arrival time (meet_rsvps.on_the_way_until).
package eta

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"strings"
	"time"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/push"
	"waypoints/server/internal/store"
)

const (
	// Kind is the push kind and the Activity kind. There is no preference column for it, so
	// it is always delivered; only friends the sender picked receive it.
	Kind push.Kind = "eta"
	// maxRecipients bounds one notice.
	maxRecipients = 20
	// onTheWayGrace keeps the meet flag up a little past the estimate.
	onTheWayGrace = 20 * time.Minute
	// maxAhead rejects arrival times further out than any drive the app routes.
	maxAhead = 24 * time.Hour
)

// Service holds the handler's dependencies.
type Service struct {
	store *store.Store
	push  *push.Service
	limit *api.Limiter
}

// Register mounts POST /v1/eta.
func Register(a *app.App) {
	s := &Service{
		store: app.MustLookup[*store.Store](a),
		limit: api.NewLimiter(10, time.Hour),
	}
	s.push, _ = app.Lookup[*push.Service](a)
	v := app.MustLookup[*auth.Verifier](a)
	a.Mux.HandleFunc("POST /v1/eta", api.Authed(v, s.share))
	app.Provide(a, s)
}

type body struct {
	Recipients  []string  `json:"recipients"`
	Destination string    `json:"destination"`
	ArriveAt    time.Time `json:"arrive_at"`
	MeetID      *string   `json:"meet_id"`
}

type result struct {
	Sent     int  `json:"sent"`
	OnTheWay bool `json:"on_the_way"`
}

func (s *Service) share(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	var b body
	if api.Decode(r, &b) != nil {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	b.Destination = strings.TrimSpace(b.Destination)
	if b.Destination == "" || len([]rune(b.Destination)) > 80 {
		api.Error(w, http.StatusBadRequest, "destination")
		return
	}
	now := time.Now()
	if b.ArriveAt.Before(now.Add(-time.Minute)) || b.ArriveAt.After(now.Add(maxAhead)) {
		api.Error(w, http.StatusBadRequest, "arrive_at")
		return
	}
	if len(b.Recipients) > maxRecipients {
		api.Error(w, http.StatusBadRequest, "recipients")
		return
	}
	if len(b.Recipients) == 0 && b.MeetID == nil {
		api.Error(w, http.StatusBadRequest, "recipients")
		return
	}
	if !s.limit.Allow(c.UserID) {
		api.Error(w, http.StatusTooManyRequests, "rate limited")
		return
	}
	pool := api.Pool(w, s.store)
	if pool == nil {
		return
	}
	ctx := r.Context()
	var out result

	if b.MeetID != nil && *b.MeetID != "" {
		tag, err := pool.Exec(ctx, `update public.meet_rsvps set on_the_way_until = $3
			where meet_id = $1::uuid and user_id = $2::uuid and status = 'going'`,
			*b.MeetID, c.UserID, b.ArriveAt.Add(onTheWayGrace))
		out.OnTheWay = err == nil && tag.RowsAffected() > 0
	}

	var ids []string
	if len(b.Recipients) > 0 {
		// Only accepted friends, never across a block.
		rows, err := pool.Query(ctx, `select u::text from unnest($2::uuid[]) u
			where exists (select 1 from public.friendships f where f.status = 'accepted'
				and least(f.requester_id, f.addressee_id) = least(u, $1::uuid)
				and greatest(f.requester_id, f.addressee_id) = greatest(u, $1::uuid))
			and not exists (select 1 from public.blocks k where (k.blocker_id = u and k.blocked_id = $1::uuid)
				or (k.blocker_id = $1::uuid and k.blocked_id = u))`, c.UserID, b.Recipients)
		if err != nil {
			api.Error(w, http.StatusBadRequest, "recipients")
			return
		}
		for rows.Next() {
			var id string
			if rows.Scan(&id) == nil {
				ids = append(ids, id)
			}
		}
		rows.Close()
	}

	if len(ids) > 0 && s.push != nil {
		name := "A friend"
		if p, err := s.store.Profile(ctx, c.UserID); err == nil && p.DisplayName != "" {
			name = p.DisplayName
		}
		url := "waypoints://profile/" + c.UserID
		if b.MeetID != nil && *b.MeetID != "" {
			url = "waypoints://meet/" + *b.MeetID
		}
		n := push.Note{
			Kind:    Kind,
			Title:   name + " is on the way",
			Body:    fmt.Sprintf("To %s. Arriving in about %s.", b.Destination, inAbout(b.ArriveAt.Sub(now))),
			URL:     url,
			ActorID: c.UserID,
			// One notice per trip: a second tap for the same arrival minute does nothing.
			Dedupe: fmt.Sprintf("eta:%s:%d", c.UserID, b.ArriveAt.Unix()/60),
		}
		go s.push.Send(context.WithoutCancel(ctx), ids, n)
		out.Sent = len(ids)
	}
	api.JSON(w, http.StatusOK, out)
}

// inAbout is "12 min" or "1 h 5 min". The recipient's time zone is unknown here, so the
// notice says how long rather than a clock time.
func inAbout(d time.Duration) string {
	m := int(math.Round(d.Minutes()))
	if m < 1 {
		m = 1
	}
	if m < 60 {
		return fmt.Sprintf("%d min", m)
	}
	if m%60 == 0 {
		return fmt.Sprintf("%d h", m/60)
	}
	return fmt.Sprintf("%d h %d min", m/60, m%60)
}
