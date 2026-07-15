// Environment-driven configuration, validated at boot with Zod.
//
// A single schema is the source of truth for every environment variable the
// backend reads. Malformed or missing-required vars crash the process at boot
// with a message listing *every* problem at once (not just the first), so a
// misconfigured deploy fails fast and legibly instead of at first use.
//
// The exported `config` singleton is computed eagerly at import time; on a
// validation failure it prints the aggregated report and exits non-zero.
// `loadConfig()` is the same logic exposed for tests — it throws `ConfigError`
// instead of exiting so it can be exercised without killing the test runner.

import { z } from 'zod';

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
  /** CORS allowed origin(s) — reflect request origin (true) or an explicit list */
  corsOrigin: string | string[] | boolean;
  /** Max participants per session */
  maxParticipantsPerSession: number;
  /** Max display name length */
  maxDisplayNameLength: number;
  /** Pino log level */
  logLevel: string;
  /** Node environment — drives pretty (dev) vs JSON (prod) logging */
  nodeEnv: string;
  /** True when NODE_ENV === 'production' */
  isProduction: boolean;
}

/** Thrown by loadConfig() on validation failure; message lists every problem. */
export class ConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigError';
  }
}

/**
 * An integer env var with a default. Absent or empty → default. Present but
 * non-numeric / out of range → a Zod issue keyed by the env var name.
 */
function intVar(def: number, opts?: { min?: number; max?: number }) {
  return z.preprocess(
    (v) => (v === undefined || v === '' ? def : v),
    z.coerce
      .number({ invalid_type_error: 'must be an integer' })
      .int('must be an integer')
      .min(opts?.min ?? Number.MIN_SAFE_INTEGER, `must be >= ${opts?.min ?? '-inf'}`)
      .max(opts?.max ?? Number.MAX_SAFE_INTEGER, `must be <= ${opts?.max ?? 'inf'}`),
  );
}

/**
 * The raw environment schema. Keys are the actual env var names so that Zod
 * issue paths name the offending variable directly. Add new vars here — and to
 * `.env.example` (a CI check enforces the two stay in sync).
 */
const envSchema = z.object({
  PORT: intVar(3000, { min: 1, max: 65535 }),
  HOST: z.preprocess((v) => (v === undefined || v === '' ? '0.0.0.0' : v), z.string()),
  LOC_UPDATE_MIN_INTERVAL_MS: intVar(900, { min: 0 }),
  STALE_THRESHOLD_SEC: intVar(10, { min: 1 }),
  OFFLINE_THRESHOLD_SEC: intVar(30, { min: 1 }),
  EVENT_BUFFER_CAPACITY: intVar(1000, { min: 1 }),
  SESSION_TTL_MS: intVar(2 * 60 * 60 * 1000, { min: 1000 }),
  CLEANUP_INTERVAL_MS: intVar(60_000, { min: 1000 }),
  CORS_ORIGIN: z.string().optional(),
  MAX_PARTICIPANTS: intVar(50, { min: 1 }),
  MAX_DISPLAY_NAME_LENGTH: intVar(30, { min: 1 }),
  LOG_LEVEL: z
    .preprocess(
      (v) => (v === undefined || v === '' ? 'info' : v),
      z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace', 'silent']),
    )
    .describe('one of: fatal, error, warn, info, debug, trace, silent'),
  NODE_ENV: z.preprocess((v) => (v === undefined || v === '' ? 'development' : v), z.string()),
});

/** Every env var the backend reads — kept in sync with `.env.example` by CI. */
export const CONFIG_ENV_KEYS: string[] = Object.keys(envSchema.shape);

/**
 * CORS_ORIGIN semantics: unset → reflect request origin (true); a single value
 * or comma-separated list → an explicit allowlist.
 */
function parseCorsOrigin(raw: string | undefined): Config['corsOrigin'] {
  if (raw === undefined || raw.trim() === '') return true;
  const parts = raw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  if (parts.length === 0) return true;
  return parts.length === 1 ? parts[0] : parts;
}

/**
 * Validate `env` and return a typed Config. Throws `ConfigError` (message lists
 * every problem) on failure. Pure — pass an explicit env for tests.
 */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues
      .map((i) => `  - ${i.path.join('.') || '(root)'}: ${i.message}`)
      .sort();
    throw new ConfigError(
      `Invalid configuration — fix the following environment variable(s):\n${problems.join('\n')}`,
    );
  }

  const v = parsed.data;
  const nodeEnv = v.NODE_ENV;
  return {
    port: v.PORT,
    host: v.HOST,
    locUpdateMinIntervalMs: v.LOC_UPDATE_MIN_INTERVAL_MS,
    staleThresholdSec: v.STALE_THRESHOLD_SEC,
    offlineThresholdSec: v.OFFLINE_THRESHOLD_SEC,
    eventBufferCapacity: v.EVENT_BUFFER_CAPACITY,
    sessionTtlMs: v.SESSION_TTL_MS,
    cleanupIntervalMs: v.CLEANUP_INTERVAL_MS,
    corsOrigin: parseCorsOrigin(v.CORS_ORIGIN),
    maxParticipantsPerSession: v.MAX_PARTICIPANTS,
    maxDisplayNameLength: v.MAX_DISPLAY_NAME_LENGTH,
    logLevel: v.LOG_LEVEL,
    nodeEnv,
    isProduction: nodeEnv === 'production',
  };
}

/**
 * The validated config singleton. On failure prints the aggregated report and
 * exits non-zero — a deploy with bad config never reaches "listening".
 */
export const config: Config = (() => {
  try {
    return loadConfig();
  } catch (err) {
    if (err instanceof ConfigError) {
      // eslint-disable-next-line no-console
      console.error(`\n${err.message}\n`);
      process.exit(1);
    }
    throw err;
  }
})();
