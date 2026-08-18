// HELLO handshake handler: authenticate, send WELCOME + SNAPSHOT + EVENTS.

import type { ValidatedHelloPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession, bindConnectionToSession } from './handler.js';
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

  // A reconnect, not a first join. Decided before the flag is set below.
  const isRejoin = participant.hasJoined;

  // Bind connection to session/participant
  conn.sessionId = sessionId;
  conn.participantId = participantId;
  bindConnectionToSession(conn, sessionId);

  // Update participant state
  participant.connId = conn.connId;
  participant.status = 'online';
  participant.lastSeenTs = Date.now();
  participant.hasJoined = true;

  // 1. Send WELCOME
  sendJson(conn.ws, {
    type: 'WELCOME',
    payload: {
      connId: conn.connId,
      sessionId,
      participantId,
      hostParticipantId: session.hostParticipantId,
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

  // 4. Broadcast PARTICIPANT_JOINED — first join only.
  //
  // Re-emitting on every reconnect burns event ids and renders a spurious
  // "X joined" in any UI that shows them, which on a flaky connection means
  // one per backoff cycle. Presence already conveys the reconnect: the
  // participant's status returns to `online` in the snapshot.
  if (!isRejoin) {
    const event = sessionStore.pushEvent(sessionId, 'PARTICIPANT_JOINED', {
      participantId,
      displayName: participant.displayName,
    });
    if (event) {
      broadcastToSession(sessionId, { type: 'EVENT', payload: event });
    }
  }
}
