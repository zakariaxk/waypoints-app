// SET_DESTINATION handler: update session destination, broadcast.

import type { ValidatedSetDestinationPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

export function handleSetDestination(
  conn: ConnState,
  payload: ValidatedSetDestinationPayload,
): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Update destination
  session.destination = {
    lat: payload.lat,
    lng: payload.lng,
    label: payload.label,
  };

  // Push event and broadcast
  const event = sessionStore.pushEvent(sessionId, 'DESTINATION_SET', {
    lat: payload.lat,
    lng: payload.lng,
    label: payload.label,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
