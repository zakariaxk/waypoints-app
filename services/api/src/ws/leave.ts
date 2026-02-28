// LEAVE_SESSION handler: mark participant offline, broadcast, close connection.

import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

export function handleLeaveSession(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  // Mark participant as offline and clear connection
  participant.connId = null;
  participant.status = 'offline';

  // Broadcast PARTICIPANT_LEFT event
  const event = sessionStore.pushEvent(sessionId, 'PARTICIPANT_LEFT', {
    participantId,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }

  // Unbind connection so handleDisconnect doesn't double-fire
  conn.sessionId = null;
  conn.participantId = null;

  // Close the WebSocket
  conn.ws.close(1000, 'Left session');
}
