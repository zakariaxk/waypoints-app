// LOC_UPDATE handler: validate rate limit, update state, broadcast.

import type { ValidatedLocUpdatePayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';
import { config } from '../config.js';

export function handleLocUpdate(conn: ConnState, payload: ValidatedLocUpdatePayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  // Rate limit: drop if too fast
  const now = Date.now();
  if (now - participant.lastLocUpdateTs < config.locUpdateMinIntervalMs) {
    return; // silently drop
  }

  // Update participant state
  participant.lastLocation = {
    lat: payload.lat,
    lng: payload.lng,
    speed: payload.speed,
    heading: payload.heading,
    accuracy: payload.accuracy,
    ts: payload.ts,
  };
  participant.lastSeenTs = now;
  participant.lastLocUpdateTs = now;
  participant.status = 'online';

  // Battery is presence enrichment, not its own event kind: it is
  // high-frequency and worthless on replay, so it rides the location stream
  // and lives on participant state (DECISIONS: battery-not-an-event).
  // Absent fields leave the last known value in place rather than clearing it.
  if (payload.battery !== undefined) participant.battery = payload.battery;
  if (payload.charging !== undefined) participant.charging = payload.charging;

  // Push event and broadcast
  const event = sessionStore.pushEvent(sessionId, 'LOCATION_UPDATED', {
    participantId,
    lat: payload.lat,
    lng: payload.lng,
    speed: payload.speed,
    heading: payload.heading,
    accuracy: payload.accuracy,
    ts: payload.ts,
    battery: participant.battery ?? null,
    charging: participant.charging ?? null,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
