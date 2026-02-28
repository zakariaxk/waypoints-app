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

  // Push event and broadcast
  const event = sessionStore.pushEvent(sessionId, 'LOCATION_UPDATED', {
    participantId,
    lat: payload.lat,
    lng: payload.lng,
    speed: payload.speed,
    heading: payload.heading,
    accuracy: payload.accuracy,
    ts: payload.ts,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
