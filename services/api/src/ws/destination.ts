// SET_DESTINATION + CLEAR_DESTINATION handlers.

import type { ValidatedSetDestinationPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

/** Check if participant is the session host. */
function isHost(sessionId: string, participantId: string): boolean {
  const session = sessionStore.getSession(sessionId);
  return session?.hostParticipantId === participantId;
}

export function handleSetDestination(
  conn: ConnState,
  payload: ValidatedSetDestinationPayload,
): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Only host can set destination
  if (!isHost(sessionId, participantId)) {
    sendJson(conn.ws, {
      type: 'ERROR',
      payload: { code: 'FORBIDDEN', message: 'Only the session host can set the destination' },
    });
    return;
  }

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
    setBy: participantId,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}

export function handleClearDestination(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Only host can clear destination
  if (!isHost(sessionId, participantId)) {
    sendJson(conn.ws, {
      type: 'ERROR',
      payload: { code: 'FORBIDDEN', message: 'Only the session host can clear the destination' },
    });
    return;
  }

  session.destination = null;

  const event = sessionStore.pushEvent(sessionId, 'DESTINATION_CLEARED', {
    clearedBy: participantId,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
