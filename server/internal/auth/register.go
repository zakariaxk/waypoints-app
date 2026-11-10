// Package auth verifies Supabase access tokens.
//
// Production tokens are checked against the project's JWKS
// (SUPABASE_URL/auth/v1/.well-known/jwks.json), cached in memory and refetched
// when an unknown key id appears (at most once every 30 s). Two HS256 paths
// exist for local work: WAYPOINTS_DEV_JWT_SECRET, honoured only when
// WAYPOINTS_ENV=dev, and WAYPOINTS_BENCH_SECRET, honoured only with -bench
// (which itself requires WAYPOINTS_ENV=bench).
package auth

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"waypoints/server/internal/app"
)

var benchFlag = flag.Bool("bench", false, "benchmark mode: accept HS256 tokens signed with WAYPOINTS_BENCH_SECRET and copy client_ms into origin_ms; requires WAYPOINTS_ENV=bench")

// Bench reports whether the gateway runs with -bench.
func Bench() bool { return *benchFlag }

// Claims is what the gateway uses from a verified token.
type Claims struct {
	UserID string    // sub
	Expiry time.Time // exp
}

// ErrUnauthorized is returned for any token that does not verify.
var ErrUnauthorized = errors.New("auth: unauthorized")

// Verifier checks access tokens.
type Verifier struct {
	jwksURL   string
	issuer    string
	hsSecrets [][]byte

	mu        sync.RWMutex
	keys      map[string]crypto.PublicKey
	lastFetch time.Time
	client    *http.Client
}

// Register provides *Verifier.
func Register(a *app.App) {
	log := a.Log.With("pkg", "auth")
	v := &Verifier{keys: map[string]crypto.PublicKey{}, client: &http.Client{Timeout: 5 * time.Second}}
	if u := strings.TrimRight(a.Config.SupabaseURL, "/"); u != "" {
		v.jwksURL = u + "/auth/v1/.well-known/jwks.json"
		v.issuer = u + "/auth/v1"
	}
	if s := app.Env("WAYPOINTS_DEV_JWT_SECRET", ""); s != "" {
		if a.Config.Env == "dev" {
			v.hsSecrets = append(v.hsSecrets, []byte(s))
			log.Warn("accepting HS256 tokens signed with WAYPOINTS_DEV_JWT_SECRET (dev only)")
		} else {
			log.Warn("WAYPOINTS_DEV_JWT_SECRET ignored outside WAYPOINTS_ENV=dev")
		}
	}
	if Bench() {
		a.OnStart("auth-bench", func(context.Context) error {
			if !a.Config.IsBench() {
				return errors.New("-bench requires WAYPOINTS_ENV=bench")
			}
			if a.Config.BenchSecret == "" {
				return errors.New("-bench requires WAYPOINTS_BENCH_SECRET")
			}
			return nil
		})
		if a.Config.BenchSecret != "" {
			v.hsSecrets = append(v.hsSecrets, []byte(a.Config.BenchSecret))
		}
	}
	if v.jwksURL == "" && len(v.hsSecrets) == 0 {
		log.Warn("no SUPABASE_URL and no HS256 secret: every token will be rejected")
	}
	if v.jwksURL != "" {
		a.OnStart("auth-jwks", func(ctx context.Context) error {
			if err := v.refresh(ctx); err != nil {
				// Not fatal: keys are fetched again on the first unknown kid.
				log.Warn("jwks fetch failed", "url", v.jwksURL, "err", err)
			}
			return nil
		})
	}
	app.Provide(a, v)
}

// Verify checks signature, expiry, and (for JWKS tokens) issuer, and returns
// the subject.
func (v *Verifier) Verify(ctx context.Context, token string) (Claims, error) {
	if token == "" {
		return Claims{}, ErrUnauthorized
	}
	var claims jwt.RegisteredClaims
	parser := jwt.NewParser(
		jwt.WithValidMethods([]string{"ES256", "RS256", "HS256"}),
		jwt.WithExpirationRequired(),
		jwt.WithLeeway(30*time.Second),
	)
	_, err := parser.ParseWithClaims(token, &claims, func(t *jwt.Token) (any, error) {
		if t.Method.Alg() == "HS256" {
			if len(v.hsSecrets) == 0 {
				return nil, ErrUnauthorized
			}
			ks := make([]jwt.VerificationKey, len(v.hsSecrets))
			for i, s := range v.hsSecrets {
				ks[i] = s
			}
			return jwt.VerificationKeySet{Keys: ks}, nil
		}
		if v.jwksURL == "" {
			return nil, ErrUnauthorized
		}
		if iss, _ := t.Claims.GetIssuer(); iss != v.issuer {
			return nil, ErrUnauthorized
		}
		kid, _ := t.Header["kid"].(string)
		return v.key(ctx, kid)
	})
	if err != nil || claims.Subject == "" || claims.ExpiresAt == nil {
		return Claims{}, ErrUnauthorized
	}
	return Claims{UserID: claims.Subject, Expiry: claims.ExpiresAt.Time}, nil
}

// FromRequest verifies the Authorization: Bearer header.
func (v *Verifier) FromRequest(r *http.Request) (Claims, error) {
	h := r.Header.Get("Authorization")
	tok, ok := strings.CutPrefix(h, "Bearer ")
	if !ok {
		return Claims{}, ErrUnauthorized
	}
	return v.Verify(r.Context(), strings.TrimSpace(tok))
}

func (v *Verifier) key(ctx context.Context, kid string) (crypto.PublicKey, error) {
	v.mu.RLock()
	k, ok := v.keys[kid]
	stale := time.Since(v.lastFetch) > 30*time.Second
	v.mu.RUnlock()
	if ok {
		return k, nil
	}
	if !stale {
		return nil, ErrUnauthorized
	}
	if err := v.refresh(ctx); err != nil {
		return nil, ErrUnauthorized
	}
	v.mu.RLock()
	defer v.mu.RUnlock()
	if k, ok := v.keys[kid]; ok {
		return k, nil
	}
	return nil, ErrUnauthorized
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Crv string `json:"crv"`
	X   string `json:"x"`
	Y   string `json:"y"`
	N   string `json:"n"`
	E   string `json:"e"`
}

func (v *Verifier) refresh(ctx context.Context) error {
	v.mu.Lock()
	v.lastFetch = time.Now()
	v.mu.Unlock()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.jwksURL, nil)
	if err != nil {
		return err
	}
	resp, err := v.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("jwks: HTTP %d", resp.StatusCode)
	}
	var set struct{ Keys []jwk }
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&set); err != nil {
		return fmt.Errorf("jwks: %w", err)
	}
	keys := map[string]crypto.PublicKey{}
	for _, k := range set.Keys {
		if pk, err := k.public(); err == nil {
			keys[k.Kid] = pk
		}
	}
	v.mu.Lock()
	v.keys = keys
	v.mu.Unlock()
	return nil
}

func b64(s string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(s) }

func (k jwk) public() (crypto.PublicKey, error) {
	switch k.Kty {
	case "EC":
		if k.Crv != "P-256" {
			return nil, errors.New("unsupported curve")
		}
		x, err := b64(k.X)
		if err != nil {
			return nil, err
		}
		y, err := b64(k.Y)
		if err != nil {
			return nil, err
		}
		if len(x) > 32 || len(y) > 32 {
			return nil, errors.New("bad EC point")
		}
		pt := make([]byte, 65)
		pt[0] = 4
		copy(pt[33-len(x):33], x)
		copy(pt[65-len(y):], y)
		return ecdsa.ParseUncompressedPublicKey(elliptic.P256(), pt)
	case "RSA":
		n, err := b64(k.N)
		if err != nil {
			return nil, err
		}
		e, err := b64(k.E)
		if err != nil {
			return nil, err
		}
		return &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}, nil
	}
	return nil, errors.New("unsupported key type")
}
