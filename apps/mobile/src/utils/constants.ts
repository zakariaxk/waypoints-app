// API base URL — change for real device testing to your machine's LAN IP.
export const API_URL = process.env.EXPO_PUBLIC_API_URL || 'http://localhost:3000';
export const WS_URL = process.env.EXPO_PUBLIC_WS_URL || 'ws://localhost:3000';

// Location polling interval in ms
export const LOCATION_INTERVAL_MS = 1000;

// Presence thresholds (client-side display hints)
export const STALE_THRESHOLD_MS = 10_000;
export const OFFLINE_THRESHOLD_MS = 30_000;
