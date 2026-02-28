// Route fetching via OSRM public API (free, no API key).

export interface RouteCoord {
  latitude: number;
  longitude: number;
}

export interface RouteResult {
  coords: RouteCoord[];
  /** Estimated duration in seconds from OSRM */
  durationSec: number;
  /** Distance in meters from OSRM */
  distanceM: number;
}

const OSRM_BASE = 'https://router.project-osrm.org/route/v1/driving';

/**
 * Fetch a driving route between two points using OSRM.
 * Returns route coordinates + duration/distance, or null on failure.
 */
export async function fetchRoute(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
): Promise<RouteResult | null> {
  try {
    const url = `${OSRM_BASE}/${from.lng},${from.lat};${to.lng},${to.lat}?overview=full&geometries=geojson`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);

    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timeout);

    if (!res.ok) return null;

    const data = await res.json();
    if (data.code !== 'Ok' || !data.routes?.length) return null;

    const route = data.routes[0];
    const geoCoords: [number, number][] = route.geometry.coordinates;
    // GeoJSON is [lng, lat], we need { latitude, longitude }
    const coords = geoCoords.map(([lng, lat]) => ({ latitude: lat, longitude: lng }));

    return {
      coords,
      durationSec: route.duration ?? 0,
      distanceM: route.distance ?? 0,
    };
  } catch {
    return null;
  }
}

/**
 * Fetch only duration + distance between two points (no geometry needed).
 * Lighter-weight than fetchRoute — uses overview=false.
 */
export async function fetchDuration(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
): Promise<{ durationSec: number; distanceM: number } | null> {
  try {
    const url = `${OSRM_BASE}/${from.lng},${from.lat};${to.lng},${to.lat}?overview=false`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);

    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timeout);

    if (!res.ok) return null;

    const data = await res.json();
    if (data.code !== 'Ok' || !data.routes?.length) return null;

    return {
      durationSec: data.routes[0].duration ?? 0,
      distanceM: data.routes[0].distance ?? 0,
    };
  } catch {
    return null;
  }
}
