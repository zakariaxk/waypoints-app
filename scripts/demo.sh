#!/usr/bin/env bash
# Boot the Waypoints backend for a two-device demo and print the LAN URL.
#
# The mobile client resolves the backend from Expo's hostUri, so a phone on the
# same Wi-Fi needs no configuration — but knowing the URL makes it obvious
# when the two devices are on different networks, which is the usual failure.
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${PORT:-3000}"

echo "==> Building shared types (api and mobile resolve @waypoints/shared from dist/)"
npm run build:shared

LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "")

echo
echo "Backend      http://localhost:${PORT}"
if [ -n "$LAN_IP" ]; then
  echo "On your LAN  http://${LAN_IP}:${PORT}   <- both phones must reach this"
fi
echo "Health       curl http://localhost:${PORT}/health"
echo
echo "In a second terminal:  npm run dev:mobile"
echo "Then scan the Expo QR on two devices on this same network."
echo
echo "Demo path: create on A -> join on B -> both markers move -> raise SOS on A"
echo "  -> B banners -> kill B's network 30s while A chats -> restore -> B has the chat."
echo
echo "Note: sessions live in memory. Restarting this process clears them all."
echo

exec npm run dev:api
