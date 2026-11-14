#!/usr/bin/env bash
# `make dev` (PRD 7.1): local Supabase up, reset and seeded, server/.env and
# ios/App/Config.xcconfig written from `supabase status`, then the gateway in the foreground.
#
#   tools/dev/dev.sh            everything
#   NO_RESET=1 tools/dev/dev.sh keep the current database
#   NO_GATEWAY=1 tools/dev/dev.sh stop after writing the config files
set -euo pipefail
cd "$(dirname "$0")/../.."
ROOT=$PWD

need() { command -v "$1" >/dev/null || { echo "dev: $1 is not installed (make dev-install)" >&2; exit 1; }; }
need supabase
need docker
need go
docker info >/dev/null 2>&1 || { echo "dev: Docker is not running" >&2; exit 1; }

echo "==> supabase start"
supabase start >/dev/null

if [ -z "${NO_RESET:-}" ]; then
  echo "==> supabase db reset (migrations + seed.sql)"
  supabase db reset
fi

# KEY="value" lines: API_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL, JWT_SECRET, ...
STATUS=$(supabase status -o env)
get() { printf '%s\n' "$STATUS" | sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" | head -n1; }
API_URL=$(get API_URL)
ANON_KEY=$(get ANON_KEY)
[ -n "$ANON_KEY" ] || ANON_KEY=$(get PUBLISHABLE_KEY)
SERVICE_ROLE_KEY=$(get SERVICE_ROLE_KEY)
[ -n "$SERVICE_ROLE_KEY" ] || SERVICE_ROLE_KEY=$(get SECRET_KEY)
DB_URL=$(get DB_URL)
JWT_SECRET=$(get JWT_SECRET)
: "${API_URL:?supabase status printed no API_URL}"
: "${ANON_KEY:?supabase status printed no ANON_KEY}"

GATEWAY_PORT=${GATEWAY_PORT:-8080}
INTERNAL_SECRET=${WAYPOINTS_INTERNAL_SECRET:-dev-internal-secret}

echo "==> server/.env"
cat > server/.env <<EOF
# Written by tools/dev/dev.sh from \`supabase status\`. Regenerated on every \`make dev\`.
WAYPOINTS_ENV=dev
WAYPOINTS_ADDR=:${GATEWAY_PORT}
SUPABASE_URL=${API_URL}
SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
DATABASE_URL=${DB_URL}
WAYPOINTS_DEV_JWT_SECRET=${JWT_SECRET}
WAYPOINTS_INTERNAL_SECRET=${INTERNAL_SECRET}
EOF

echo "==> ios/App/Config.xcconfig"
# xcconfig treats // as a comment, so the scheme separator is written /\$()/.
esc() { printf '%s' "$1" | sed 's#://#:/$()/#'; }
LINK_HOST=""
if [ -f ios/App/Config.xcconfig ]; then
  LINK_HOST=$(sed -n 's/^LINK_HOST *= *//p' ios/App/Config.xcconfig | head -n1)
fi
cat > ios/App/Config.xcconfig <<EOF
// Written by tools/dev/dev.sh from \`supabase status\`. Regenerated on every \`make dev\`.
SUPABASE_URL = $(esc "$API_URL")
SUPABASE_ANON_KEY = ${ANON_KEY}
GATEWAY_URL = http:/\$()/127.0.0.1:${GATEWAY_PORT}
LINK_HOST = ${LINK_HOST}
EOF

# Push triggers call the gateway through pg_net (plan 7.7). From inside the database
# container the host is host.docker.internal.
if command -v psql >/dev/null && [ -n "$DB_URL" ]; then
  psql "$DB_URL" -q -v ON_ERROR_STOP=0 <<EOF >/dev/null 2>&1 || true
alter database postgres set app.gateway_url = 'http://host.docker.internal:${GATEWAY_PORT}';
alter database postgres set app.internal_secret = '${INTERNAL_SECRET}';
EOF
fi

cat <<EOF

Local stack is up.
  Supabase API   ${API_URL}
  Studio         http://127.0.0.1:54323
  Inbucket       http://127.0.0.1:54324
  Database       ${DB_URL}
  Gateway        http://127.0.0.1:${GATEWAY_PORT}
  Seed sign-in   any *@waypoints.test, password waypoints-dev (app: -wp-login <handle>)
EOF

[ -n "${NO_GATEWAY:-}" ] && exit 0
echo "==> gateway (Ctrl-C to stop; Supabase keeps running, \`supabase stop\` to stop it)"
cd "$ROOT/server"
exec go run ./cmd/gateway
