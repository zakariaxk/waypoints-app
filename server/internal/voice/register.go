// Package voice mints LiveKit access tokens (POST /v1/voice/token) for team
// voice channels (room ch_<channel_id>) and convoys (room cv_<convoy_id>,
// CNV-11), and closes convoy rooms through LiveKit's RoomService when a
// member leaves or the convoy ends. The LiveKit secret never leaves the gateway.
package voice

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/convoy"
	"waypoints/server/internal/store"
)

type service struct {
	cfg     app.Config
	store   *store.Store
	convoys *convoy.Service
	http    *http.Client
}

// Register mounts the token endpoint and installs the convoy room closer.
func Register(a *app.App) {
	s := &service{cfg: a.Config, store: app.MustLookup[*store.Store](a), http: &http.Client{Timeout: 5 * time.Second}}
	if c, ok := app.Lookup[*convoy.Service](a); ok {
		s.convoys = c
		c.SetVoice(s)
	}
	a.Mux.HandleFunc("POST /v1/voice/token", api.Authed(app.MustLookup[*auth.Verifier](a), s.token))
}

func (s *service) configured() bool {
	return s.cfg.LiveKitURL != "" && s.cfg.LiveKitAPIKey != "" && s.cfg.LiveKitAPISecret != ""
}

func (s *service) token(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	if !s.configured() {
		api.Error(w, http.StatusServiceUnavailable, "voice unavailable")
		return
	}
	var b struct {
		ChannelID string `json:"channel_id"`
		ConvoyID  string `json:"convoy_id"`
	}
	if api.Decode(r, &b) != nil || (b.ChannelID == "") == (b.ConvoyID == "") {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
	p, perr := s.store.Profile(r.Context(), cl.UserID)
	name := cl.UserID
	if perr == nil && p.DisplayName != "" {
		name = p.DisplayName
	}
	var room, identity string
	if b.ConvoyID != "" {
		// Convoy rooms: current members only, identified by realtime uid so a
		// leaving member can be removed by uid (ConvoyLeft).
		if perr != nil || s.convoys == nil || !s.convoys.IsMember(b.ConvoyID, p.UID) {
			api.Error(w, http.StatusForbidden, "not a member")
			return
		}
		room, identity = "cv_"+b.ConvoyID, strconv.FormatUint(p.UID, 10)
	} else {
		pool := api.Pool(w, s.store)
		if pool == nil {
			return
		}
		var member bool
		err := pool.QueryRow(r.Context(), `select exists (select 1 from public.channels c
			join public.team_members m on m.team_id = c.team_id
			where c.id = $1 and c.kind = 'voice' and m.user_id = $2)`, b.ChannelID, cl.UserID).Scan(&member)
		if err != nil || !member {
			api.Error(w, http.StatusForbidden, "not a member")
			return
		}
		room, identity = "ch_"+b.ChannelID, cl.UserID
	}
	signed, err := s.sign(identity, name, 6*time.Hour, map[string]any{
		"room": room, "roomJoin": true, "canPublish": true, "canSubscribe": true,
	})
	if err != nil {
		api.Error(w, http.StatusInternalServerError, "token")
		return
	}
	api.JSON(w, http.StatusOK, map[string]string{"url": s.cfg.LiveKitURL, "token": signed})
}

func (s *service) sign(identity, name string, ttl time.Duration, video map[string]any) (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"iss":   s.cfg.LiveKitAPIKey,
		"sub":   identity,
		"nbf":   now.Unix(),
		"exp":   now.Add(ttl).Unix(),
		"video": video,
	}
	if name != "" {
		claims["name"] = name
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(s.cfg.LiveKitAPISecret))
}

// ConvoyLeft implements convoy.VoiceRooms: the member drops out of the room.
func (s *service) ConvoyLeft(convoyID string, uid uint64) {
	room := "cv_" + convoyID
	s.roomService("RemoveParticipant", room, map[string]any{"room": room, "identity": strconv.FormatUint(uid, 10)})
}

// ConvoyEnded implements convoy.VoiceRooms: the room closes with the convoy.
func (s *service) ConvoyEnded(convoyID string) {
	room := "cv_" + convoyID
	s.roomService("DeleteRoom", room, map[string]any{"room": room})
}

// roomService calls LiveKit's Twirp RoomService. Failures are logged only: a
// room nobody is in does not exist, and LiveKit closes empty rooms itself.
func (s *service) roomService(method, room string, body map[string]any) {
	if !s.configured() {
		return
	}
	tok, err := s.sign("waypoints-gateway", "", time.Minute, map[string]any{"room": room, "roomAdmin": true, "roomCreate": true})
	if err != nil {
		return
	}
	base := s.cfg.LiveKitURL
	base = strings.Replace(base, "wss://", "https://", 1)
	base = strings.Replace(base, "ws://", "http://", 1)
	raw, _ := json.Marshal(body)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		strings.TrimRight(base, "/")+"/twirp/livekit.RoomService/"+method, bytes.NewReader(raw))
	if err != nil {
		return
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	resp, err := s.http.Do(req)
	if err != nil {
		slog.Debug("livekit room service", "method", method, "room", room, "err", err)
		return
	}
	_ = resp.Body.Close()
}
