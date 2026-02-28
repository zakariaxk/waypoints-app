// Geo utility functions: haversine distance, ETA estimation.

const EARTH_RADIUS_KM = 6371;

/** Degrees to radians. */
function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/**
 * Haversine distance between two coordinates in kilometers.
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
 * Format distance for display: "0.3 km", "1.2 km", "15 km", "230 m".
 */
export function formatDistance(km: number): string {
  if (km < 0.1) return `${Math.round(km * 1000)} m`;
  if (km < 10) return `${km.toFixed(1)} km`;
  return `${Math.round(km)} km`;
}

/**
 * Estimate ETA given distance in km and speed in m/s.
 * Returns null if speed is unavailable or zero.
 */
export function estimateETA(distKm: number, speedMs: number | null): string | null {
  if (!speedMs || speedMs <= 0.5) return null; // stationary or no data
  const timeSeconds = (distKm * 1000) / speedMs;
  if (timeSeconds < 60) return '<1 min';
  if (timeSeconds < 3600) return `${Math.round(timeSeconds / 60)} min`;
  const hours = Math.floor(timeSeconds / 3600);
  const mins = Math.round((timeSeconds % 3600) / 60);
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}
