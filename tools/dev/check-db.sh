#!/usr/bin/env bash
# `make check-db` (PRD 7.1): runs supabase/checks.sql against the local database and exits
# non-zero if any line it prints contains FAIL, or if psql itself fails.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v psql >/dev/null || { echo "check-db: psql is not installed (brew install libpq && brew link --force libpq)" >&2; exit 1; }

DB_URL=${DATABASE_URL:-}
if [ -z "$DB_URL" ] && command -v supabase >/dev/null; then
  DB_URL=$(supabase status -o env 2>/dev/null | sed -n 's/^DB_URL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -n1)
fi
DB_URL=${DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}

OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT
set +e
psql "$DB_URL" -X -q -v ON_ERROR_STOP=1 -f supabase/checks.sql >"$OUT" 2>&1
STATUS=$?
set -e
cat "$OUT"

FAILS=$(grep -c 'FAIL' "$OUT" || true)
PASSES=$(grep -c 'PASS' "$OUT" || true)
echo
echo "check-db: ${PASSES} PASS, ${FAILS} FAIL"
if [ "$STATUS" -ne 0 ]; then
  echo "check-db: psql exited ${STATUS}" >&2
  exit "$STATUS"
fi
[ "$FAILS" -eq 0 ]
