// Hook that periodically fetches OSRM driving duration for each participant to the destination.
// Returns a Map<participantId, { durationSec, distanceM }>.

import { useEffect, useRef, useState, useCallback } from 'react';
import type { Participant, Destination } from '../state/session-store';
import { fetchDuration } from '../utils/routing';
import { haversineDistance } from '../utils/geo';

export interface ParticipantETA {
  durationSec: number;
  distanceM: number;
}

/** Minimum movement (km) before re-fetching a participant's ETA */
const MOVEMENT_THRESH_KM = 0.05; // 50m

/** How often (ms) to refresh ETAs */
const REFRESH_INTERVAL_MS = 15_000; // 15s

/** Delay (ms) between individual participant fetches to avoid flooding OSRM */
const STAGGER_MS = 300;

/**
 * Format OSRM duration in seconds to a human-readable ETA string.
 */
export function formatDuration(seconds: number): string {
  if (seconds < 60) return '<1 min';
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`;
  const hours = Math.floor(seconds / 3600);
  const mins = Math.round((seconds % 3600) / 60);
  return mins > 0 ? `${hours}h ${mins}m` : `${hours}h`;
}

interface LastFetch {
  lat: number;
  lng: number;
  destLat: number;
  destLng: number;
}

export function useParticipantETAs(
  participants: Map<string, Participant>,
  destination: Destination | null,
): Map<string, ParticipantETA> {
  const [etas, setEtas] = useState<Map<string, ParticipantETA>>(new Map());
  const lastFetchRef = useRef<Map<string, LastFetch>>(new Map());
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => { mountedRef.current = false; };
  }, []);

  const fetchAll = useCallback(async () => {
    if (!destination) {
      setEtas(new Map());
      lastFetchRef.current.clear();
      return;
    }

    const toFetch: { pid: string; loc: { lat: number; lng: number } }[] = [];

    for (const [pid, p] of participants) {
      if (!p.lastLocation) continue;

      const last = lastFetchRef.current.get(pid);
      if (last) {
        const moved = haversineDistance(p.lastLocation.lat, p.lastLocation.lng, last.lat, last.lng);
        const destChanged = last.destLat !== destination.lat || last.destLng !== destination.lng;
        if (!destChanged && moved < MOVEMENT_THRESH_KM) continue; // skip — hasn't moved enough
      }

      toFetch.push({ pid, loc: p.lastLocation });
    }

    if (toFetch.length === 0) return;

    // Stagger calls to be polite to the public OSRM server
    const updates = new Map<string, ParticipantETA>();

    for (let i = 0; i < toFetch.length; i++) {
      if (!mountedRef.current) return;
      const { pid, loc } = toFetch[i];

      const result = await fetchDuration(loc, destination);
      if (result && mountedRef.current) {
        updates.set(pid, { durationSec: result.durationSec, distanceM: result.distanceM });
        lastFetchRef.current.set(pid, {
          lat: loc.lat,
          lng: loc.lng,
          destLat: destination.lat,
          destLng: destination.lng,
        });
      }

      // Stagger delay between participants (except last)
      if (i < toFetch.length - 1) {
        await new Promise((r) => setTimeout(r, STAGGER_MS));
      }
    }

    if (mountedRef.current && updates.size > 0) {
      setEtas((prev) => {
        const next = new Map(prev);
        for (const [pid, eta] of updates) next.set(pid, eta);
        // Remove ETAs for participants no longer in the session
        for (const pid of next.keys()) {
          if (!participants.has(pid)) next.delete(pid);
        }
        return next;
      });
    }
  }, [participants, destination]);

  // Fetch immediately when destination changes or new participants arrive
  useEffect(() => {
    if (!destination) {
      setEtas(new Map());
      lastFetchRef.current.clear();
      return;
    }
    fetchAll();
  }, [destination?.lat, destination?.lng, participants]);

  // Periodic refresh
  useEffect(() => {
    if (!destination) return;
    const timer = setInterval(fetchAll, REFRESH_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [destination, fetchAll]);

  return etas;
}
