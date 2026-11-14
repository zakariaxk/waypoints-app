// Package push sends APNs notifications directly over HTTP/2 with a
// token-based (ES256) provider key, and serves POST /internal/notify for the
// Postgres pg_net triggers (DMs, mentions, friend requests). Section 6.
//
// Every notification also becomes a row in public.notifications, the Activity list (NTF-6).
// Only events about you are sent; there are no marketing pushes (NTF-7).
//
// Without APNs configuration it logs what it would have sent.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/subtle"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"waypoints/server/internal/app"
	"waypoints/server/internal/geo"
	"waypoints/server/internal/metrics"
	"waypoints/server/internal/store"
)

// Kind names a notification preference (S3).
type Kind string

const (
	MeetsNearby    Kind = "meets_nearby"
	FriendRequests Kind = "friend_requests"
	Messages       Kind = "messages"
	Mentions       Kind = "mentions"
	ConvoyInvites  Kind = "convoy_invites"
	MeetReminders  Kind = "meet_reminders"
)

// Note is one notification.
type Note struct {
	Kind  Kind
	Title string
	Body  string
	URL   string // waypoints:// deep link

	// Activity row (NTF-6). ActorID is the person who caused it, if any. Dedupe makes the
	// event notify each recipient at most once (NTF-7). Recorded means the database trigger
	// already wrote the rows, so Send only pushes.
	ActorID  string
	Dedupe   string
	Recorded bool
}

// activityKind is the notifications.kind for a push kind.
func activityKind(k Kind) string {
	switch k {
	case MeetsNearby:
		return "meet_nearby"
	case FriendRequests:
		return "friend_request"
	case Messages:
		return "dm"
	case Mentions:
		return "mention"
	case ConvoyInvites:
		return "convoy_invite"
	case MeetReminders:
		return "meet_changed"
	}
	return string(k)
}

// meetsNearbyPerDay caps meets-nearby alerts per person per rolling day (NTF-7).
const meetsNearbyPerDay = 3

// Service sends notifications.
type Service struct {
	store  *store.Store
	log    *slog.Logger
	cfg    app.Config
	key    *ecdsa.PrivateKey
	client *http.Client
	sent   *metrics.Counter
	failed *metrics.Counter

	mu     sync.Mutex
	token  string
	issued time.Time
}

// Register provides *Service and mounts /internal/notify.
func Register(a *app.App) {
	s := &Service{
		store:  app.MustLookup[*store.Store](a),
		log:    a.Log.With("pkg", "push"),
		cfg:    a.Config,
		client: &http.Client{Timeout: 10 * time.Second},
		sent:   a.Metrics.Counter("push_sent_total", "APNs notifications accepted.", nil),
		failed: a.Metrics.Counter("push_failed_total", "APNs notifications rejected or not sent.", nil),
	}
	if a.Config.APNsKeyPath != "" {
		if k, err := loadKey(a.Config.APNsKeyPath); err == nil {
			s.key = k
		} else {
			s.log.Warn("apns key unusable; notifications are logged only", "err", err)
		}
	}
	a.Mux.HandleFunc("POST /internal/notify", s.handleNotify)
	app.Provide(a, s)
}

func loadKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, fmt.Errorf("no PEM block")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("not an EC key")
	}
	return ec, nil
}

func (s *Service) providerToken() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != "" && time.Since(s.issued) < 50*time.Minute {
		return s.token, nil
	}
	t := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": s.cfg.APNsTeamID, "iat": time.Now().Unix()})
	t.Header["kid"] = s.cfg.APNsKeyID
	signed, err := t.SignedString(s.key)
	if err != nil {
		return "", err
	}
	s.token, s.issued = signed, time.Now()
	return signed, nil
}

// Send records an activity row for every recipient (unless n.Recorded) and delivers n to
// every device of every newly recorded user who has n.Kind turned on.
func (s *Service) Send(ctx context.Context, userIDs []string, n Note) {
	pool := s.store.Pool()
	if pool == nil || len(userIDs) == 0 {
		s.log.Info("push (no database)", "kind", n.Kind, "users", len(userIDs), "title", n.Title)
		return
	}
	if !n.Recorded {
		userIDs = s.record(ctx, userIDs, n)
		if len(userIDs) == 0 {
			return
		}
	}
	rows, err := pool.Query(ctx, `select d.apns_token, d.environment::text from public.device_tokens d
		left join public.notification_prefs p on p.user_id = d.user_id
		where d.user_id = any($1::uuid[])
		  and coalesce((to_jsonb(p) ->> $2)::boolean, true)`, userIDs, string(n.Kind))
	if err != nil {
		s.log.Warn("push query", "err", err)
		return
	}
	type dev struct{ token, env string }
	var devs []dev
	for rows.Next() {
		var d dev
		if rows.Scan(&d.token, &d.env) == nil {
			devs = append(devs, d)
		}
	}
	rows.Close()
	for _, d := range devs {
		s.deliver(ctx, d.token, d.env, n)
	}
}

// record writes one notifications row per recipient and returns the recipients it wrote,
// dropping the actor, blocked pairs, and repeats of the same event. If the table is missing
// it returns everyone so pushes still go out.
func (s *Service) record(ctx context.Context, userIDs []string, n Note) []string {
	pool := s.store.Pool()
	rows, err := pool.Query(ctx, `select u::text from unnest($1::uuid[]) u
		where public.record_notification(u, $2, nullif($3, '')::uuid, nullif($4, ''), $5, nullif($6, ''), nullif($7, ''))`,
		userIDs, activityKind(n.Kind), n.ActorID, n.URL, n.Title, n.Body, n.Dedupe)
	if err != nil {
		s.log.Warn("activity insert", "err", err)
		return userIDs
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			out = append(out, id)
		}
	}
	if rows.Err() != nil {
		s.log.Warn("activity insert", "err", rows.Err())
		return userIDs
	}
	return out
}

func (s *Service) deliver(ctx context.Context, token, env string, n Note) {
	if s.key == nil {
		s.log.Info("push (apns not configured)", "kind", n.Kind, "title", n.Title, "body", n.Body)
		return
	}
	jwtTok, err := s.providerToken()
	if err != nil {
		s.failed.Inc()
		return
	}
	host := "https://api.push.apple.com"
	if env == "sandbox" {
		host = "https://api.sandbox.push.apple.com"
	}
	payload, _ := json.Marshal(map[string]any{
		"aps":  map[string]any{"alert": map[string]string{"title": n.Title, "body": n.Body}, "sound": "default"},
		"url":  n.URL,
		"kind": n.Kind,
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+token, bytes.NewReader(payload))
	req.Header.Set("authorization", "bearer "+jwtTok)
	req.Header.Set("apns-topic", s.cfg.APNsTopic)
	req.Header.Set("apns-push-type", "alert")
	resp, err := s.client.Do(req)
	if err != nil {
		s.failed.Inc()
		return
	}
	resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		s.sent.Inc()
		return
	}
	s.failed.Inc()
	if resp.StatusCode == http.StatusGone || resp.StatusCode == http.StatusBadRequest {
		if pool := s.store.Pool(); pool != nil {
			_, _ = pool.Exec(ctx, `delete from public.device_tokens where apns_token = $1`, token)
		}
	}
}

// MeetNearby notifies users whose presence cell lies within their own radius
// of a new public meet.
func (s *Service) MeetNearby(ctx context.Context, hostID, meetID, title string, latE7, lngE7 int32) {
	pool := s.store.Pool()
	if pool == nil {
		return
	}
	rows, err := pool.Query(ctx, `select p.user_id::text, p.h3_r7, s.notify_radius_km from public.user_presence_cell p
		join public.privacy_settings s on s.user_id = p.user_id
		where s.notify_meets_nearby and p.user_id <> $1
		  and not exists (select 1 from public.blocks b where (b.blocker_id = p.user_id and b.blocked_id = $1)
		                                              or (b.blocker_id = $1 and b.blocked_id = p.user_id))`, hostID)
	if err != nil {
		return
	}
	var ids []string
	for rows.Next() {
		var id string
		var cell int64
		var km int
		if rows.Scan(&id, &cell, &km) != nil {
			continue
		}
		clat, clng := geo.Centre(uint64(cell))
		if geo.DistanceM(clat, clng, latE7, lngE7) <= math.Max(1, float64(km))*1000 {
			ids = append(ids, id)
		}
	}
	rows.Close()
	ids = s.underDailyCap(ctx, ids)
	s.Send(ctx, ids, Note{Kind: MeetsNearby, Title: "Meet nearby", Body: title, URL: "waypoints://meet/" + meetID,
		ActorID: hostID, Dedupe: "meet_nearby:" + meetID})
}

// underDailyCap drops users who already had meetsNearbyPerDay meets-nearby alerts in the
// last 24 hours (NTF-7). The notifications table is the count, since Send records first.
func (s *Service) underDailyCap(ctx context.Context, ids []string) []string {
	pool := s.store.Pool()
	if pool == nil || len(ids) == 0 {
		return ids
	}
	rows, err := pool.Query(ctx, `select user_id::text from public.notifications
		where user_id = any($1::uuid[]) and kind = 'meet_nearby' and created_at > now() - interval '24 hours'
		group by user_id having count(*) >= $2`, ids, meetsNearbyPerDay)
	if err != nil {
		s.log.Warn("meets nearby cap", "err", err)
		return ids
	}
	capped := map[string]bool{}
	for rows.Next() {
		var id string
		if rows.Scan(&id) == nil {
			capped[id] = true
		}
	}
	rows.Close()
	out := ids[:0:0]
	for _, id := range ids {
		if !capped[id] {
			out = append(out, id)
		}
	}
	return out
}

// MeetChanged notifies everyone who RSVP'd.
func (s *Service) MeetChanged(ctx context.Context, meetID, title, body string) {
	pool := s.store.Pool()
	if pool == nil {
		return
	}
	rows, err := pool.Query(ctx, `select user_id::text from public.meet_rsvps where meet_id = $1`, meetID)
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
	s.Send(ctx, ids, Note{Kind: MeetReminders, Title: title, Body: body, URL: "waypoints://meet/" + meetID})
}

type notifyBody struct {
	Kind        string   `json:"kind"` // dm, mention, friend_request, convoy_invite
	RecipientID string   `json:"recipient_id"`
	Recipients  []string `json:"recipients"`
	ActorID     string   `json:"actor_id"`
	RefID       string   `json:"ref_id"`
	Preview     string   `json:"preview"`
}

func (s *Service) handleNotify(w http.ResponseWriter, r *http.Request) {
	secret := s.cfg.InternalSecret
	got := r.Header.Get("X-Waypoints-Secret")
	if secret == "" || subtle.ConstantTimeCompare([]byte(secret), []byte(got)) != 1 {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var b notifyBody
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&b) != nil {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}
	ids := b.Recipients
	if b.RecipientID != "" {
		ids = append(ids, b.RecipientID)
	}
	name := "Someone"
	if b.ActorID != "" {
		if p, err := s.store.Profile(r.Context(), b.ActorID); err == nil && p.DisplayName != "" {
			name = p.DisplayName
		}
	}
	var n Note
	switch b.Kind {
	case "dm":
		n = Note{Kind: Messages, Title: name, Body: b.Preview, URL: "waypoints://thread/" + b.RefID}
	case "mention":
		n = Note{Kind: Mentions, Title: name + " mentioned you", Body: b.Preview, URL: "waypoints://channel/" + b.RefID}
	case "friend_request":
		n = Note{Kind: FriendRequests, Title: "Friend request", Body: name + " wants to be friends.", URL: "waypoints://profile/" + b.ActorID}
	case "convoy_invite":
		n = Note{Kind: ConvoyInvites, Title: "Convoy invite", Body: name + " invited you to a convoy.", URL: "waypoints://convoy/" + b.RefID}
	default:
		http.Error(w, "kind", http.StatusBadRequest)
		return
	}
	n.Recorded = true // the trigger wrote the activity rows (migration W7-2)
	go s.Send(context.WithoutCancel(r.Context()), ids, n)
	w.WriteHeader(http.StatusAccepted)
}
