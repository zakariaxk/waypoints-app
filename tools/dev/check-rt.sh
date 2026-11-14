#!/usr/bin/env bash
# `make check-rt` (PRD 7.1): starts a throwaway gateway in bench mode with the in-memory store
# on its own ports, runs server/cmd/rtdebug against it, and stops it. Exits with rtdebug's
# status. ARGS are passed to rtdebug (for example ARGS="-only ghost,convoy -v").
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT=${RT_PORT:-18180}
MPORT=${RT_METRICS_PORT:-19190}
export WAYPOINTS_ENV=bench WAYPOINTS_BENCH_SECRET=${WAYPOINTS_BENCH_SECRET:-rtdebug-secret}
export DATABASE_URL= SUPABASE_URL= NATS_URL= WAYPOINTS_LOG_LEVEL=${WAYPOINTS_LOG_LEVEL:-warn}
export WAYPOINTS_ADDR=127.0.0.1:$PORT WAYPOINTS_METRICS_ADDR=127.0.0.1:$MPORT
export WAYPOINTS_ENV_FILE=/dev/null

mkdir -p .build
(cd server && go build -o ../.build/gateway ./cmd/gateway && go build -o ../.build/rtdebug ./cmd/rtdebug)

./.build/gateway -bench -tick "${TICK:-100ms}" &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

# shellcheck disable=SC2086
./.build/rtdebug -url "http://127.0.0.1:$PORT" -metrics "http://127.0.0.1:$MPORT" \
  -secret "$WAYPOINTS_BENCH_SECRET" ${ARGS:-}
