// Package voice mints LiveKit access tokens for team voice channels
// (POST /v1/voice/token). The LiveKit secret never leaves the gateway.
package voice

import (
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"waypoints/server/internal/api"
	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
	"waypoints/server/internal/store"
)

type service struct {
	cfg   app.Config
	store *store.Store
}

// Register mounts the token endpoint.
func Register(a *app.App) {
	s := &service{cfg: a.Config, store: app.MustLookup[*store.Store](a)}
	a.Mux.HandleFunc("POST /v1/voice/token", api.Authed(app.MustLookup[*auth.Verifier](a), s.token))
}

func (s *service) token(w http.ResponseWriter, r *http.Request, cl auth.Claims) {
	if s.cfg.LiveKitURL == "" || s.cfg.LiveKitAPIKey == "" || s.cfg.LiveKitAPISecret == "" {
		api.Error(w, http.StatusServiceUnavailable, "voice unavailable")
		return
	}
	var b struct {
		ChannelID string `json:"channel_id"`
	}
	if api.Decode(r, &b) != nil || b.ChannelID == "" {
		api.Error(w, http.StatusBadRequest, "bad body")
		return
	}
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
	name := cl.UserID
	if p, err := s.store.Profile(r.Context(), cl.UserID); err == nil && p.DisplayName != "" {
		name = p.DisplayName
	}
	now := time.Now()
	t := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"iss":  s.cfg.LiveKitAPIKey,
		"sub":  cl.UserID,
		"name": name,
		"nbf":  now.Unix(),
		"exp":  now.Add(6 * time.Hour).Unix(),
		"video": map[string]any{
			"room": "ch_" + b.ChannelID, "roomJoin": true, "canPublish": true, "canSubscribe": true,
		},
	})
	signed, err := t.SignedString([]byte(s.cfg.LiveKitAPISecret))
	if err != nil {
		api.Error(w, http.StatusInternalServerError, "token")
		return
	}
	api.JSON(w, http.StatusOK, map[string]string{"url": s.cfg.LiveKitURL, "token": signed})
}
