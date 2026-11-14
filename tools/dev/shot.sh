#!/usr/bin/env bash
# `make shot NAME=<n> ARGS="..."` (PRD 7.1): boots the simulator, installs the last debug build,
# launches it with the launch arguments, waits for the screen to settle, and writes
# .build/shots/<n>.png.
#
#   make shot NAME=map ARGS="-wp-login marcus_s2k"
#   make shot NAME=g6 ARGS="-wp-preview -wp-open waypoints://debug/modsim"
#   WAIT=8 make shot NAME=feed ARGS="-wp-preview -wp-open waypoints://debug/feed"
#
# BUILD=0 skips the xcodebuild step (reuse the installed .app). LOCATION="lat,lon" pins the
# simulated location first (default: Cherry Hill, NJ, where the seed lives).
set -euo pipefail
cd "$(dirname "$0")/../.."

NAME=${NAME:?NAME is required, for example make shot NAME=map ARGS="-wp-preview"}
ARGS=${ARGS:-}
SIMULATOR=${SIMULATOR:-iPhone 16}
BUNDLE_ID=${BUNDLE_ID:-app.waypoints.ios}
DERIVED_DATA=${DERIVED_DATA:-$PWD/.build/DerivedData}
WAIT=${WAIT:-6}
LOCATION=${LOCATION:-39.9387,-75.0230}
APP="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Waypoints.app"

if [ "${BUILD:-1}" != "0" ] || [ ! -d "$APP" ]; then
  make generate >/dev/null
  (cd ios && xcodebuild -project Waypoints.xcodeproj -scheme Waypoints \
    -destination "platform=iOS Simulator,name=$SIMULATOR" -derivedDataPath "$DERIVED_DATA" -quiet build)
fi

xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null
# A fixed status bar so screenshots compare.
xcrun simctl status_bar "$SIMULATOR" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR" "$APP"
xcrun simctl privacy "$SIMULATOR" grant location "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl location "$SIMULATOR" set "$LOCATION" >/dev/null 2>&1 || true
xcrun simctl terminate "$SIMULATOR" "$BUNDLE_ID" >/dev/null 2>&1 || true

# shellcheck disable=SC2086
xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID" $ARGS >/dev/null
sleep "$WAIT"

mkdir -p .build/shots
OUT=.build/shots/$NAME.png
xcrun simctl io "$SIMULATOR" screenshot "$OUT" >/dev/null
echo "shot: $OUT"
