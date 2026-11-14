#!/usr/bin/env bash
# CMP-7: the App Store screenshot set, from preview seed data (PRD 7.1 harness).
#
#   tools/screenshots/shots.sh            both sizes
#   tools/screenshots/shots.sh 6.9        one size
#
# Writes .build/screenshots/<size>/<nn>-<name>.png in upload order. Each shot is
# `make shot NAME=... ARGS="-wp-preview -wp-open waypoints://debug/<screen>"` run on
# the size's simulator; when the Makefile has no `shot` target yet, the same steps
# run here directly with simctl.
#
# Debug screen names follow PRD 7.1 (`waypoints://debug/<screen>`). If the harness
# names a screen differently, change the SHOTS table only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

BUNDLE_ID=app.waypoints.ios
DERIVED="$ROOT/.build/DerivedData"
OUT="$ROOT/.build/screenshots"
SETTLE="${SETTLE:-6}"

# size | simulator name | device type id (created if missing)
SIZES=(
  "6.9|iPhone 16 Pro Max|com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro-Max"
  "6.5|iPhone 11 Pro Max|com.apple.CoreSimulator.SimDeviceType.iPhone-11-Pro-Max"
)

# order | name | debug screen
SHOTS=(
  "01|map|map"                 # live map with friends, a meet pin, reports
  "02|meet|meet"               # meet sheet: who's going, venue notes, Roll out
  "03|route|route-preview"     # route preview with the low-car score
  "04|mod|mod-simulator"       # mod simulator with est. ranges
  "05|garage|garage-car"       # a garage car with its build log
  "06|showdown|showdown"       # Showdown vote
  "07|team|team-channel"       # a team text channel with the voice strip
  "08|market|market"           # market browse, fits filter on
)

want="${1:-}"

has_make_shot() { make -n shot NAME=probe ARGS= >/dev/null 2>&1; }

ensure_sim() { # name devtype -> prints udid
  local name="$1" type="$2" udid
  udid="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
name=sys.argv[1]
for rt,devs in json.load(sys.stdin)["devices"].items():
    if "iOS" in rt:
        for d in devs:
            if d["name"]==name: print(d["udid"]); sys.exit()
' "$name")"
  if [ -z "$udid" ]; then
    local runtime
    runtime="$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]]
print(rs[-1]["identifier"])')"
    udid="$(xcrun simctl create "$name" "$type" "$runtime")"
  fi
  echo "$udid"
}

clean_status_bar() {
  xcrun simctl status_bar "$1" override --time 9:41 --dataNetwork 5g --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
}

build_once() {
  [ -n "${BUILT:-}" ] && return
  make generate
  (cd ios && xcodebuild -project Waypoints.xcodeproj -scheme Waypoints -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DERIVED" \
    -skipPackagePluginValidation -quiet build)
  BUILT=1
}

direct_shot() { # udid out screen
  local udid="$1" out="$2" screen="$3"
  build_once
  xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/Waypoints.app"
  xcrun simctl privacy "$udid" grant location "$BUNDLE_ID" || true
  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$udid" "$BUNDLE_ID" -wp-preview -wp-open "waypoints://debug/$screen" >/dev/null
  sleep "$SETTLE"
  xcrun simctl io "$udid" screenshot --type=png "$out" >/dev/null
}

for size_row in "${SIZES[@]}"; do
  IFS='|' read -r size sim type <<<"$size_row"
  [ -n "$want" ] && [ "$want" != "$size" ] && continue
  udid="$(ensure_sim "$sim" "$type")"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  clean_status_bar "$udid"
  mkdir -p "$OUT/$size"
  echo "==> $size\" on $sim"
  for shot_row in "${SHOTS[@]}"; do
    IFS='|' read -r order name screen <<<"$shot_row"
    screen="${screen%%#*}"; screen="${screen// /}"
    dest="$OUT/$size/$order-$name.png"
    if has_make_shot; then
      make shot SIMULATOR="$sim" NAME="store-$size-$name" \
        ARGS="-wp-preview -wp-open waypoints://debug/$screen"
      cp ".build/shots/store-$size-$name.png" "$dest"
    else
      direct_shot "$udid" "$dest" "$screen"
    fi
    echo "    $dest"
  done
  xcrun simctl status_bar "$udid" clear || true
done
