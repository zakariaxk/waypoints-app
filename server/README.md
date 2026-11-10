# Waypoints gateway

Go realtime gateway: WebSocket fan-out of live location (`/v1/rt`) and a small JSON API. Design: `docs/PLAN.md` sections 6 and 7.

## Run

```sh
cd server
go run ./cmd/gateway
curl localhost:8080/healthz          # ok
curl 127.0.0.1:9090/metrics          # Prometheus text
```

SIGINT or SIGTERM starts a graceful shutdown: `/healthz` turns 503, background tasks are cancelled, the HTTP servers drain, stop hooks close live connections, and the process exits within `WAYPOINTS_SHUTDOWN_TIMEOUT`.

## Configuration

Read from the environment. If `server/.env` exists (or the file named by `WAYPOINTS_ENV_FILE`), its `KEY=VALUE` lines are applied first without overriding variables already set. `.env` is git-ignored.

| Variable | Default | Used for |
|---|---|---|
| `WAYPOINTS_ENV` | `dev` | `dev`, `bench`, or `prod`. `-bench` refuses to start unless this is `bench`. |
| `WAYPOINTS_ADDR` | `:8080` (or `:$PORT` if `PORT` is set) | Public listener: `/healthz`, `/v1/...`, `/internal/...`. |
| `WAYPOINTS_METRICS_ADDR` | `127.0.0.1:9090` | Private listener: `/metrics`, `/debug/pprof/`. Never expose publicly. |
| `WAYPOINTS_NODE` | hostname | Node name in logs and `Welcome.node`. |
| `WAYPOINTS_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error`. |
| `WAYPOINTS_LOG_FORMAT` | `text` in dev, else `json` | `text` or `json`, to stderr. |
| `WAYPOINTS_SHUTDOWN_TIMEOUT` | `5s` | Upper bound on graceful shutdown. |
| `SUPABASE_URL` | | Project URL; JWKS for token verification is under it. |
| `SUPABASE_SERVICE_ROLE_KEY` | | Server-side Supabase calls. |
| `DATABASE_URL` | | Postgres connection string (pgx). |
| `NATS_URL` | empty | Set to run multi-node over NATS; empty means single-node, in-process bus. |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | | Voice token minting. |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_TOPIC` | | APNs auth key (`.p8` path) and bundle id. |
| `APNS_ENV` | `sandbox` | `sandbox` or `production`. |
| `WAYPOINTS_INTERNAL_SECRET` | | Shared secret header for `POST /internal/notify` (pg_net trigger). |
| `WAYPOINTS_BENCH_SECRET` | | HS256 key accepted for tokens only under `-bench`. |

Command-line flags are declared by the package that uses them (for example `-tick` and `-bench` in `internal/ws`); `go run ./cmd/gateway -h` lists them.

## Layout

- `cmd/gateway`: `main`. Calls `Register(*app.App)` on every `internal/` package in a fixed order.
- `internal/app`: config, logger, metrics registry, the public and debug muxes, the typed service registry (`app.Provide`, `app.Lookup`, `app.MustLookup`), and lifecycle hooks (`OnStart`, `OnStop`, `Go`).
- `internal/wire`: generated Go protobuf from `proto/`. Regenerate with `make proto` (`tools/proto.sh`); never edit by hand.
- `internal/metrics`: dependency-free counters, gauges, and histograms in Prometheus text format.
- The other `internal/` packages own the parts of section 7; until built, their `Register` is empty.
