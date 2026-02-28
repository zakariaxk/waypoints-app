// HELLO handshake handler: authenticate, send WELCOME + SNAPSHOT + EVENTS.

import type { ValidatedHelloPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

export function handleHello(conn: ConnState, payload: ValidatedHelloPayload): void {
  const { sessionId, participantId, token, lastEventId } = payload;

  // Validate session exists
  const session = sessionStore.getSession(sessionId);
  if (!session) {
    sendJson(conn.ws, {
      type: 'ERROR',
      payload: { code: 'NOT_IN_SESSION', message: 'Session not found' },
    });
    return;
  }

  // Validate participant exists and token matches
  const participant = session.participants.get(participantId);
  if (!participant || participant.token !== token) {
    sendJson(conn.ws, {
      type: 'ERROR',
      payload: { code: 'UNAUTHORIZED', message: 'Invalid credentials' },
    });
    return;
  }

  // Bind connection to session/participant
  conn.sessionId = sessionId;
  conn.participantId = participantId;

  // Update participant state
  participant.connId = conn.connId;
  participant.status = 'online';
  participant.lastSeenTs = Date.now();

  // 1. Send WELCOME
  sendJson(conn.ws, {
    type: 'WELCOME',
    payload: {
      connId: conn.connId,
      sessionId,
      participantId,
      latestEventId: session.lastEventId,
    },
  });

  // 2. Send SNAPSHOT
  const snapshot = sessionStore.buildSnapshot(sessionId);
  if (snapshot) {
    sendJson(conn.ws, { type: 'SNAPSHOT', payload: snapshot });
  }

  // 3. Send missed EVENTS if reconnecting
  if (lastEventId !== null && lastEventId < session.lastEventId) {
    const missed = sessionStore.getMissedEvents(sessionId, lastEventId);
    if (missed && missed.length > 0) {
      sendJson(conn.ws, {
        type: 'EVENTS',
        payload: {
          fromEventId: lastEventId,
          toEventId: session.lastEventId,
          events: missed,
        },
      });
    }
    // If missed is null, gap too large — client uses SNAPSHOT only
  }

  // 4. Broadcast PARTICIPANT_JOINED event to all in session
  const event = sessionStore.pushEvent(sessionId, 'PARTICIPANT_JOINED', { participantId });
  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
