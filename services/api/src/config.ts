// Environment-driven configuration with sensible MVP defaults.

export interface Config {
  port: number;
  host: string;
  /** Min ms between LOC_UPDATE per participant */
  locUpdateMinIntervalMs: number;
  /** Seconds before participant is marked stale */
  staleThresholdSec: number;
  /** Seconds before participant is marked offline */
  offlineThresholdSec: number;
  /** Max events kept in ring buffer per session */
  eventBufferCapacity: number;
  /** Session TTL in ms (cleanup empty sessions older than this) */
  sessionTtlMs: number;
  /** Interval between session cleanup sweeps in ms */
  cleanupIntervalMs: number;
  /** CORS allowed origin(s) — '*' for dev, specific URL for production */
  corsOrigin: string | string[] | boolean;
  /** Max participants per session */
  maxParticipantsPerSession: number;
  /** Max display name length */
  maxDisplayNameLength: number;
}

function envInt(key: string, fallback: number): number {
  const v = process.env[key];
  if (v === undefined) return fallback;
  const n = parseInt(v, 10);
  return isNaN(n) ? fallback : n;
}

export const config: Config = {
  port: envInt('PORT', 3000),
  host: process.env.HOST || '0.0.0.0',
  locUpdateMinIntervalMs: envInt('LOC_UPDATE_MIN_INTERVAL_MS', 900),
  staleThresholdSec: envInt('STALE_THRESHOLD_SEC', 10),
  offlineThresholdSec: envInt('OFFLINE_THRESHOLD_SEC', 30),
  eventBufferCapacity: envInt('EVENT_BUFFER_CAPACITY', 1000),
  sessionTtlMs: envInt('SESSION_TTL_MS', 2 * 60 * 60 * 1000), // 2 hours
  cleanupIntervalMs: envInt('CLEANUP_INTERVAL_MS', 60_000), // 60s
  corsOrigin: process.env.CORS_ORIGIN || true, // true = reflect request origin
  maxParticipantsPerSession: envInt('MAX_PARTICIPANTS', 50),
  maxDisplayNameLength: envInt('MAX_DISPLAY_NAME_LENGTH', 30),
};
