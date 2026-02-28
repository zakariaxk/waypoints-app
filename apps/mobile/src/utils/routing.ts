// Route fetching via OSRM public API (free, no API key).

export interface RouteCoord {
  latitude: number;
  longitude: number;
}

const OSRM_BASE = 'https://router.project-osrm.org/route/v1/driving';

/**
 * Fetch a driving route between two points using OSRM.
 * Returns an array of coordinates for a Polyline, or null on failure.
 */
export async function fetchRoute(
  from: { lat: number; lng: number },
  to: { lat: number; lng: number },
): Promise<RouteCoord[] | null> {
  try {
    const url = `${OSRM_BASE}/${from.lng},${from.lat};${to.lng},${to.lat}?overview=full&geometries=geojson`;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);

    const res = await fetch(url, { signal: controller.signal });
    clearTimeout(timeout);

    if (!res.ok) return null;

    const data = await res.json();
    if (data.code !== 'Ok' || !data.routes?.length) return null;

    const coords: [number, number][] = data.routes[0].geometry.coordinates;
    // GeoJSON is [lng, lat], we need { latitude, longitude }
    return coords.map(([lng, lat]) => ({ latitude: lat, longitude: lng }));
  } catch {
    return null;
  }
}
