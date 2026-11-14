#!/usr/bin/env bash
# `make drive ROUTE=<name>` (PRD 7.1): grants location to the app and feeds the booted
# simulator a moving location along tools/dev/routes/<name>.txt through `simctl location
# start`. SPEED is metres per second (default 15, about 54 km/h); INTERVAL is seconds between
# fixes (default 1). `make drive ROUTE=stop` clears the simulated location.
#
#   make drive ROUTE=route-70
#   SIMULATOR="iPhone 16 Pro" make drive ROUTE=pine-barrens SPEED=25
set -euo pipefail
cd "$(dirname "$0")/../.."

ROUTE=${1:-${ROUTE:-}}
SIMULATOR=${SIMULATOR:-iPhone 16}
BUNDLE_ID=${BUNDLE_ID:-app.waypoints.ios}
SPEED=${SPEED:-15}
INTERVAL=${INTERVAL:-1}

if [ -z "$ROUTE" ]; then
  echo "usage: make drive ROUTE=<name>   routes:" >&2
  ls tools/dev/routes | sed 's/\.txt$//; s/^/  /' >&2
  exit 2
fi

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
DEVICE=$SIMULATOR

if [ "$ROUTE" = "stop" ]; then
  xcrun simctl location "$DEVICE" clear
  echo "drive: location cleared"
  exit 0
fi

FILE=tools/dev/routes/$ROUTE.txt
[ -f "$FILE" ] || { echo "drive: no route $FILE" >&2; exit 2; }

# Some permission changes terminate the app; grant before moving.
xcrun simctl privacy "$DEVICE" grant location "$BUNDLE_ID" || true
xcrun simctl privacy "$DEVICE" grant location-always "$BUNDLE_ID" || true

POINTS=$(grep -v '^[[:space:]]*#' "$FILE" | grep -v '^[[:space:]]*$')
FIRST=$(printf '%s\n' "$POINTS" | head -n1)
xcrun simctl location "$DEVICE" set "$FIRST"
echo "drive: $ROUTE on $DEVICE at ${SPEED} m/s ($(printf '%s\n' "$POINTS" | wc -l | tr -d ' ') waypoints)"
printf '%s\n' "$POINTS" | xcrun simctl location "$DEVICE" start --speed="$SPEED" --interval="$INTERVAL" -
echo "drive: running in the simulator; \`make drive ROUTE=stop\` to clear"
