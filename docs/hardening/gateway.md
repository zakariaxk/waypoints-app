# Gateway hardening report

Scope: `server/**` (except `server/internal/push/**`, owned by another agent),
`deploy/**`, `tools/dev/**`. Bench tooling (`bench/**`) was read-only.
Checklist items: 4 (identity/authorization), 5 (rate limits and memory
bounds), 6 (dev/deploy safety), 10 (input validation), 11 (internal
endpoints), 20-server (logging, recovery, health, metrics).

## Item 4 — identity and authorization

Identity on every route and frame comes from the verified JWT
(`auth.Verifier.FromRequest` / `Verify` on the WebSocket `Hello` frame). No
handler reads a user id, uid, or membership claim from the body, query, or
path. Per-route audit:

| Route | Identity | Authorization / target check |
|---|---|---|
| `GET /healthz`, `GET /readyz` | none | liveness/readiness only |
| `GET /v1/rt` (WS) | `Hello.access_token` → `Verify`, re-checked on `RefreshToken` (same `sub` required) and token expiry re-checked per frame | all frames act on `c.uid`/`c.userID` |
| `PUT /v1/privacy` | Bearer JWT | writes only `claims.UserID`'s settings; body carries no identity |
| `POST /v1/reports` | Bearer JWT | `author_id = claims.UserID`; kind/coords/note validated |
| `POST /v1/reports/{id}/vote` | Bearer JWT | vote row keyed `user_id = claims.UserID`; report fetched by id |
| `DELETE /v1/reports/{id}` | Bearer JWT | `author_id = claims.UserID` and < 5 min old |
| `POST /v1/meets` | Bearer JWT | `host_id = claims.UserID`; team meets require `canHostForTeam` |
| `PATCH /v1/meets/{id}` | Bearer JWT | `m.HostID == claims.UserID` (`hostMeet`) |
| `DELETE /v1/meets/{id}` | Bearer JWT | same host check |
| `POST /v1/convoys` | Bearer JWT | `LeaderID/LeaderUID` from claims + profile |
| `POST /v1/convoys/join` | Bearer JWT | join code only; membership granted by code possession |
| `PUT /v1/convoys/{id}/destination`, `DELETE .../regroup` | Bearer JWT | `leaderConvoy`: `uid == c.LeaderUID` |
| `PUT /v1/convoys/{id}/regroup` | Bearer JWT | any current member (`c.has(uid)`) |
| `DELETE /v1/convoys/{id}` | Bearer JWT | leader only |
| `POST /v1/convoys/{id}/invite` | Bearer JWT | current member; recipients are arbitrary `user_ids` (see findings) |
| `POST /v1/voice/token` | Bearer JWT | team channel: `team_members` row for `claims.UserID`; convoy: `IsMember(convoyID, profile.UID)` |
| `GET /v1/voice/occupants` | Bearer JWT | per-channel `team_members` membership re-checked; others omitted |
| `GET/POST /v1/help`, `GET /v1/help/{id}` | Bearer JWT | list scoped to requester/friends/teammates/opted-in nearby; blocks and suspensions excluded in SQL |
| `POST /v1/help/{id}/respond` | Bearer JWT | cannot respond to own request; `help_responses.user_id = claims.UserID` |
| `DELETE /v1/help/{id}`, `PUT /v1/help/{id}/extend` | Bearer JWT | `requester_id = claims.UserID` in the UPDATE itself |
| `POST /v1/eta` | Bearer JWT | recipients filtered to accepted friends minus blocks in SQL; sender is claims user |
| `POST /internal/notify` | `X-Waypoints-Secret` shared secret | constant-time compare; no user identity accepted from body for authz (fields are content only) |
| `POST /dev/*` | none | 404 unless `WAYPOINTS_ENV` is `dev`/`bench` **and** the store is in-memory |

WebSocket client frames (`proto/waypoints/v1/realtime.proto`):

| Frame | Identity | Notes |
|---|---|---|
| `Hello` | carries the access token | verified once at connect; expiry re-checked every frame |
| `LocationUpdate` | connection's `uid` | `geo.Valid` coords, 400 ms min interval, privacy policy applied before publish |
| `SetViewport` | connection | cell/agg subscriptions only; bounds via `geo.Cover`/`MaxCover` |
| `Ping` | connection | replies `Pong` |
| `JoinConvoy`/`LeaveConvoy` | connection `uid` | `ConvoyAuthority.IsMember` / `Leave`; no client-supplied uid trusted |
| `RefreshToken` | new token's `sub` must equal connection `userID` | re-verified signature+expiry |
| `SetHomeZones` | connection | capped at 3 zones, radius ≤ 300 m |

Bench/dev fail-closed: `WAYPOINTS_ENV` now defaults to `prod` when unset
(`server/internal/app/config.go`). Unknown values are rejected as before.
`prod` refuses to start without `SUPABASE_URL`, `DATABASE_URL`, and
`WAYPOINTS_INTERNAL_SECRET`; `bench` refuses to start with `DATABASE_URL` or
`SUPABASE_URL` set; dev and bench refuse a non-loopback `DATABASE_URL`.
`WAYPOINTS_BENCH_SECRET` is cleared unless `WAYPOINTS_ENV=bench`, and the
existing gates remain: `-bench` requires `bench`, `WAYPOINTS_DEV_JWT_SECRET`
is honoured only in `dev`. `/dev/*` mounts only in `dev`/`bench` with an
in-memory store.

## Item 5 — rate limits and memory bounds

New shared limiter: `server/internal/app/limit.go` (`app.Limiter`, per-key
sliding window with opportunistic sweep so the key map is bounded; the old
`api.Limiter` now aliases it).

- **Pre-auth per-IP**: `app.publicHandler` (wraps the public mux) allows
  1200 req/min per client IP (`X-Forwarded-For` rightmost entry, else
  `RemoteAddr`) on all `/v1/*` JSON routes; exempts `/healthz`, `/readyz`,
  `/dev/*`, `/v1/rt`, and gives `/internal/*` a tighter 300/min. Bench mode
  skips IP limits (load generators dial from loopback by design).
- **Per-user post-auth**: `api.Authed` allows 120 req/min per `sub` on every
  authenticated JSON route; `privacy.handlePut` (own auth path) has the same.
- **Endpoint-specific**: voice token mint 30/hr, voice occupants 30/min,
  ETA shares 10/hr (pre-existing), help create 6/hr + 3/day in Postgres
  (pre-existing), report create 10/10 min in Postgres (pre-existing), report
  vote/undo 60/hr, meet update/cancel 30/hr, convoy create 10/hr, convoy join
  30/hr.
- **WebSocket**: per-IP upgrade attempts 300/min (skipped in bench); global
  connection cap `WAYPOINTS_MAX_CONNS` (default 65536) checked pre-upgrade
  and post-auth; max 8 concurrent connections per account. Per-connection
  token buckets on every frame family: any frame 100/s, viewport 5/s,
  ping 5/s, convoy join/leave 0.5/s, home zones 0.2/s, token refresh 0.2/s;
  location keeps its existing 400 ms minimum interval. Drops counted in
  `ws_frame_rate_dropped_total` / `ws_location_rate_dropped_total`.
- **Join codes**: 6 chars from a 32-char alphabet (~1.07B values) — already
  unguessable; added exact-format validation (length 6 + alphabet) before any
  lookup and the 30/hr per-user attempt limit above.
- **Memory bounds**: limiter maps sweep stale keys; `api.Limiter` previously
  grew one slice per key forever. Convoy `byID`/`byCode` entries are removed
  when a convoy ends; live convoys persist by design (mirrored to Postgres).
  Outbox reliable lane is bounded (64) with slow-consumer close; per-conn
  cell/agg subscriptions are bounded by `geo.MaxCover`; shard topic maps are
  garbage-collected when empty. Residual: shard `cell.last` maps can retain
  last-known positions per publisher per cell — bounded by real publisher
  count, noted for follow-up.

## Item 6 — dev scripts and deployment

- `tools/dev/dev.sh`: `supabase status` is now read **before**
  `supabase db reset`; `API_URL` and `DB_URL` hosts must be
  `127.0.0.1`/`localhost`/`::1` or the script exits.
- `tools/dev/check-db.sh`: refuses a non-loopback `DATABASE_URL` host.
- `deploy/Dockerfile`: runs as non-root user `gateway` (uid 10001); only
  port 8080 exposed (metrics/pprof bind loopback inside the container).
- `deploy/compose.yml`: `WAYPOINTS_ENV=prod` pinned (overrides `.env`),
  `cap_drop: ALL`, `no-new-privileges`, `restart: unless-stopped` on all
  services; no ports published for gateway or NATS — only Caddy 80/443.
- `.dockerignore` (new, repo root): excludes `.env*` files, `.git`, `ios/`,
  `docs/`, `.build/`, bench results — `server/.env` can no longer be baked
  into the image.
- `deploy/Caddyfile`: `/dev/*` answered 404 at the edge.
- `deploy/README.md`: hardening notes added (TLS via Caddy, internal
  endpoints, secrets handling, prod env requirements).

## Item 10 — input validation

- `api.Decode` now rejects unknown fields (`DisallowUnknownFields`) and
  trailing JSON, on top of the existing 64 KB `MaxBytesReader`. Same strict
  decode added to `PUT /v1/privacy` (trailing check) and the `/dev/*`
  handlers. `/internal/notify` already had a 16 KB cap (push package,
  read-only this round).
- Validation already present and confirmed: coordinates via `geo.Valid`
  (reports, meets, convoys, regroup, destination, help), enums for report
  kind / meet kind+visibility+recurrence / help kind / privacy levels,
  lengths (report note 120, help note 120, meet title 50/details 500/place
  80, convoy name 40, polyline 64 KB, ETA destination 80, recipients ≤ 20,
  invite list ≤ 50, occupants channel list ≤ 50, home zones ≤ 3 radius ≤
  300 m), heading clamped to 360, `arrive_at` window, UUID-shaped ids flow
  only into parameterized queries.
- WebSocket frame size: `ws.SetReadLimit(16 KiB)` on the socket — unchanged,
  already correct.

## Item 11 — internal endpoints

- `POST /internal/notify` (`server/internal/push/register.go`, read-only):
  already uses `crypto/subtle.ConstantTimeCompare` on
  `X-Waypoints-Secret`, rejects empty configured secret, caps body at 16 KB.
- It is **intentionally** on the public listener: Supabase's pg_net trigger
  calls it over the internet, so it cannot be moved to the private mux.
  Defence in depth added outside the file: `/internal/*` gets a dedicated
  300/min per-IP limiter in `app.publicHandler`, and `prod` now refuses to
  start without `WAYPOINTS_INTERNAL_SECRET`. The DB function already
  no-ops when URL/secret are unset and is `security definer` with execute
  revoked from public roles.
- Metrics/pprof stay on the private `WAYPOINTS_METRICS_ADDR` listener
  (default `127.0.0.1:9090`), unexposed in compose; Caddy only proxies the
  public mux.

## Item 20 (server) — logging, recovery, health, metrics

- **Panic recovery**: HTTP handlers via `app.publicHandler` recover → 500 +
  `http_panics_total`; WebSocket `conn.run`, `writer`, the pinger timer
  callback, and the outbox overflow/slow-consumer callbacks each recover and
  log (hijacked sockets escape net/http's recovery); in-process bus
  `Publish`/`Request` and the NATS subscribe callback recover per handler;
  app background tasks already recovered. `slog` logs carry no tokens,
  secrets, or coordinates (verified by inspection; the only coordinate-adjacent
  log is LiveKit room names `ch_<uuid>`/`cv_<id>` at debug level).
- **Health**: `GET /healthz` (liveness, 503 while draining) and new
  `GET /readyz` (503 while draining or when Postgres `Ping` fails; always ok
  on the in-memory dev/bench backend).
- **Metrics added**: `http_requests_total`, `http_5xx_total`,
  `http_rate_limited_total`, `http_panics_total`,
  `ws_frame_rate_dropped_total` (alongside existing ws/hub/push/runtime
  series).
- **Server timeouts**: unchanged (`ReadHeaderTimeout` 10 s); bodies are
  capped per handler. Slow-loris on request bodies is bounded by the 64 KB
  `MaxBytesReader` caps.

## Findings for the owner (not fixed here)

- `server/internal/push/**` is owned by another agent this round (read-only).
  Two items to hand back: (a) when APNs is not configured, `handleNotify`
  logs the notification title and body at info level — for DMs that is
  message content in logs; gate it to debug or drop it in prod. (b) the
  `go s.Send(...)` goroutine has no panic recovery; a panic in `Send` would
  kill the process. (The endpoint auth itself is already correct.)
- `POST /v1/convoys/{id}/invite` lets any convoy member push a notification
  to up to 50 arbitrary user ids — no friendship check (ETA shares do check).
  Consider restricting recipients to friends/teammates.
- Per-node rate limits are in-memory; a multi-node deployment multiplies
  each limit by node count. DB-backed limits exist for reports and help.
- Convoy in-memory maps only shrink on `end`; very long-lived convoys persist
  by design (they mirror Postgres). No TTL sweep was added.
- Shard `cell.last` maps retain last-known positions per publisher; bounded
  by publisher count but never idle-evicted — candidate for a future sweep.

## Verification

- `cd server && go build ./...` — clean.
- `cd server && go vet ./...` — clean.
- `cd server && go test ./...` — no test files in any package.
- `make check-rt` — 8/8 PASS (friend-precise, approximate, hidden, ghost,
  nearby-anonymous, viewport-swap, slow-consumer, convoy).
