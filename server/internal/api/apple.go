package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"waypoints/server/internal/app"
	"waypoints/server/internal/auth"
)

// Sign in with Apple token revocation (App Review 5.1.1(v)). At account
// deletion the app obtains a fresh Apple authorization code and posts it here
// with the caller's Supabase token; the gateway exchanges the code at
// appleid.apple.com and revokes the resulting refresh token, ending the user's
// Apple grant for the app.
//
// Configuration (all four required, else the endpoint answers 503):
//
//	WAYPOINTS_APPLE_CLIENT_ID    the app's bundle id (app.waypoints.ios)
//	WAYPOINTS_APPLE_TEAM_ID      Apple Developer team id (JWT iss)
//	WAYPOINTS_APPLE_KEY_ID       key id of the Sign in with Apple .p8 (JWT kid)
//	WAYPOINTS_APPLE_PRIVATE_KEY  the .p8 PEM contents, or a path to the file
func (s *Service) registerApple(a *app.App) {
	a.Mux.HandleFunc("POST /v1/apple/revoke", Authed(s.auth, s.revokeApple))
}

type appleRevoker struct {
	clientID string
	teamID   string
	keyID    string
	key      *ecdsa.PrivateKey
	log      *slog.Logger
	client   *http.Client
}

func loadAppleRevoker(a *app.App) *appleRevoker {
	clientID := app.Env("WAYPOINTS_APPLE_CLIENT_ID", "")
	teamID := app.Env("WAYPOINTS_APPLE_TEAM_ID", "")
	keyID := app.Env("WAYPOINTS_APPLE_KEY_ID", "")
	keyPEM := app.Env("WAYPOINTS_APPLE_PRIVATE_KEY", "")
	if clientID == "" || teamID == "" || keyID == "" || keyPEM == "" {
		return nil // not configured: /v1/apple/revoke answers 503
	}
	if !strings.Contains(keyPEM, "BEGIN") {
		// The value is a path to the .p8 file.
		b, err := os.ReadFile(keyPEM)
		if err != nil {
			a.Log.Error("apple revocation: cannot read WAYPOINTS_APPLE_PRIVATE_KEY", "err", err)
			return nil
		}
		keyPEM = string(b)
	}
	keyPEM = strings.ReplaceAll(keyPEM, `\n`, "\n")
	block, _ := pem.Decode([]byte(keyPEM))
	if block == nil {
		a.Log.Error("apple revocation: WAYPOINTS_APPLE_PRIVATE_KEY is not a PEM block")
		return nil
	}
	pk, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	key, ok := pk.(*ecdsa.PrivateKey)
	if err != nil || !ok {
		a.Log.Error("apple revocation: WAYPOINTS_APPLE_PRIVATE_KEY is not an EC private key", "err", err)
		return nil
	}
	return &appleRevoker{
		clientID: clientID, teamID: teamID, keyID: keyID, key: key, log: a.Log,
		client: &http.Client{Timeout: 10 * time.Second},
	}
}

// clientSecret is the ES256 JWT Apple requires as client_secret on both
// endpoints. Apple accepts a six-month lifetime; sign a fresh one per call so
// no secret is cached or logged.
func (a *appleRevoker) clientSecret() (string, error) {
	now := time.Now()
	claims := jwt.RegisteredClaims{
		Issuer:    a.teamID,
		Subject:   a.clientID,
		Audience:  jwt.ClaimStrings{"https://appleid.apple.com"},
		IssuedAt:  jwt.NewNumericDate(now),
		ExpiresAt: jwt.NewNumericDate(now.Add(180 * 24 * time.Hour)),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = a.keyID
	return token.SignedString(a.key)
}

func (a *appleRevoker) post(ctx context.Context, endpoint string, form url.Values) (int, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := a.client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, body, err
}

// revoke exchanges the authorization code for tokens, then revokes the refresh
// token so the user's Apple grant for this app ends.
func (a *appleRevoker) revoke(ctx context.Context, code string) error {
	secret, err := a.clientSecret()
	if err != nil {
		return err
	}
	status, body, err := a.post(ctx, "https://appleid.apple.com/auth/token", url.Values{
		"client_id":     {a.clientID},
		"client_secret": {secret},
		"code":          {code},
		"grant_type":    {"authorization_code"},
	})
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return errApple("token", status, body)
	}
	var tokens struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.Unmarshal(body, &tokens); err != nil || tokens.RefreshToken == "" {
		return errApple("token response", status, body)
	}
	status, body, err = a.post(ctx, "https://appleid.apple.com/auth/revoke", url.Values{
		"client_id":       {a.clientID},
		"client_secret":   {secret},
		"token":           {tokens.RefreshToken},
		"token_type_hint": {"refresh_token"},
	})
	if err != nil {
		return err
	}
	if status != http.StatusOK {
		return errApple("revoke", status, body)
	}
	return nil
}

func errApple(step string, status int, body []byte) error {
	// Apple's error bodies are small JSON ({"error": "..."}); keep them out of
	// the response but in the log for diagnosis.
	return &appleError{step: step, status: status, body: string(body)}
}

type appleError struct {
	step   string
	status int
	body   string
}

func (e *appleError) Error() string {
	return "apple " + e.step + ": http " + http.StatusText(e.status)
}

func (s *Service) revokeApple(w http.ResponseWriter, r *http.Request, c auth.Claims) {
	if s.apple == nil {
		Error(w, http.StatusServiceUnavailable, "apple revocation not configured")
		return
	}
	var body struct {
		AuthorizationCode string `json:"authorization_code"`
	}
	if Decode(r, &body) != nil || body.AuthorizationCode == "" || len(body.AuthorizationCode) > 2048 {
		Error(w, http.StatusBadRequest, "bad body")
		return
	}
	if err := s.apple.revoke(r.Context(), body.AuthorizationCode); err != nil {
		if ae, ok := err.(*appleError); ok {
			s.apple.log.Warn("apple revocation failed", "step", ae.step, "status", ae.status, "body", ae.body)
		} else {
			s.apple.log.Warn("apple revocation failed", "err", err)
		}
		Error(w, http.StatusBadGateway, "apple revocation failed")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
