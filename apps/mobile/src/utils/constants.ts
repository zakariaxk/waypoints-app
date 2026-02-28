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
