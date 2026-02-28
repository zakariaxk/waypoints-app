// Geo utility functions: haversine distance, speed, ETA — all in miles / mph.

const EARTH_RADIUS_KM = 6371;
const KM_TO_MILES = 0.621371;
const MS_TO_MPH = 2.236936;

/** Degrees to radians. */
function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * Haversine distance between two coordinates in kilometers.
 * (Internal unit stays km; call formatDistance* for display.)
 */
export function haversineDistance(
  lat1: number,
  lng1: number,
  lat2: number,
  lng2: number,
): number {
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_KM * c;
}

/**
 * Format distance for display in miles/feet.
 * Input: km (same as haversineDistance output).
 * Output: "0.3 mi", "1.2 mi", "430 ft".
 */
export function formatDistance(km: number): string {
  const miles = km * KM_TO_MILES;
  if (miles < 0.1) {
    const feet = Math.round(miles * 5280);
    return `${feet} ft`;
  }
  if (miles < 10) return `${miles.toFixed(1)} mi`;
  return `${Math.round(miles)} mi`;
}

// ─── Speed utilities ───

/**
 * Convert metres-per-second to miles-per-hour.
 */
export function msToMph(ms: number): number {
  return ms * MS_TO_MPH;
}

/**
 * Format speed for display.
 * @param speedMs GPS speed in m/s (from coords.speed). null → "—".
 * @returns e.g. "42 mph" or "—"
 */
export function formatSpeed(speedMs: number | null | undefined): string {
  if (speedMs == null || speedMs < 0) return '—';
  const mph = msToMph(speedMs);
  if (mph < 1) return '0 mph';
  return `${Math.round(mph)} mph`;
}

/**
 * Haversine-based fallback speed between two points.
 * Returns m/s estimate.
 */
export function haversineSpeed(
  lat1: number,
  lng1: number,
  ts1: number,
  lat2: number,
  lng2: number,
  ts2: number,
): number {
  const dtSec = (ts2 - ts1) / 1000;
  if (dtSec <= 0) return 0;
  const distKm = haversineDistance(lat1, lng1, lat2, lng2);
  return (distKm * 1000) / dtSec; // m/s
}

// ─── EMA smoothing ───

/**
 * Exponential moving average smoothing for speed values.
 * @param prev previous smoothed value (or null for first sample)
 * @param raw  current raw value
 * @param alpha smoothing factor 0–1 (lower = smoother, default 0.3)
 */
export function emaSmooth(prev: number | null, raw: number, alpha = 0.3): number {
  if (prev === null) return raw;
  return alpha * raw + (1 - alpha) * prev;
}

/**
 * Estimate ETA given distance in km and speed in m/s.
 * Returns null if speed is unavailable or zero.
 */
export function estimateETA(distKm: number, speedMs: number | null): string | null {
  if (!speedMs || speedMs <= 0.5) return null;
  const timeSeconds = (distKm * 1000) / speedMs;
  if (timeSeconds < 60) return '<1 min';
  if (timeSeconds < 3600) return `${Math.round(timeSeconds / 60)} min`;
  const hours = Math.floor(timeSeconds / 3600);
  const mins = Math.round((timeSeconds % 3600) / 60);
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}
