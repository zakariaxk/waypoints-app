# Deploying the gateway

Single VM: install Docker, copy `server/.env` (see `server/README.md`), set the
domain in `Caddyfile`, then `docker compose -f deploy/compose.yml up -d --build`.
Caddy terminates TLS and balances WebSocket and HTTP traffic across both nodes;
no stickiness is needed. For one node, drop `gateway-b` and `nats` and unset
`NATS_URL`.

## Hardening notes

- Containers run as a non-root user (`gateway`, uid 10001) with all
  capabilities dropped and `no-new-privileges` set.
- Only port 8080 is published, through Caddy on 80/443. The metrics/pprof
  listener binds `127.0.0.1:9090` inside the container and is not reachable
  from outside; NATS has no published port either.
- Caddy terminates TLS (automatic certificates for the configured domain).
  `/dev/*` is answered 404 at the edge as a second line of defence.
- `POST /internal/notify` is intentionally reachable from the public internet:
  Supabase's pg_net trigger calls it. It is protected by the
  `X-Waypoints-Secret` shared secret (constant-time comparison, required
  non-empty in prod), a 16 KB body cap, and a per-IP rate limit at the
  gateway.
- `WAYPOINTS_ENV=prod` is pinned in compose; prod refuses to start without
  `SUPABASE_URL`, `DATABASE_URL`, and `WAYPOINTS_INTERNAL_SECRET`, and never
  accepts HS256 dev/bench tokens.
- Secrets live only in `server/.env` on the host (git-ignored, excluded from
  the Docker build context by `.dockerignore`); nothing secret is baked into
  the image.
