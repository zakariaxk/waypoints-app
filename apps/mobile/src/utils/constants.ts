// API base URL — uses LAN IP so physical devices can reach the dev server.
// In production, set EXPO_PUBLIC_API_URL / EXPO_PUBLIC_WS_URL env vars.
import Constants from 'expo-constants';

const DEV_HOST =
  Constants.expoConfig?.hostUri?.split(':')[0] ?? 'localhost';

export const API_URL =
  process.env.EXPO_PUBLIC_API_URL || `http://${DEV_HOST}:3000`;
export const WS_URL =
  process.env.EXPO_PUBLIC_WS_URL || `ws://${DEV_HOST}:3000`;

// Location polling interval in ms
export const LOCATION_INTERVAL_MS = 1000;

// Presence thresholds (client-side display hints)
export const STALE_THRESHOLD_MS = 10_000;
export const OFFLINE_THRESHOLD_MS = 30_000;

// If no inbound WS traffic arrives for this long, treat the socket as dead and
// reconnect. Must be comfortably longer than the server heartbeat interval.
export const WS_RECEIVE_TIMEOUT_MS = 45_000;

// Distance from the destination within which ARRIVAL_PING is accepted.
// Must match ARRIVAL_RADIUS_M on the server.
export const ARRIVAL_RADIUS_M = 50;

// Battery level below which a participant is badged as low (when not charging).
export const LOW_BATTERY_THRESHOLD = 0.15;
