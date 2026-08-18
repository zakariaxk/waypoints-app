// LEAVE_SESSION handler: remove participant, broadcast, close connection.

import type { ConnState } from './handler.js';
import { broadcastToSession, releaseConnection } from './handler.js';
import { sessionStore } from '../state/session-store.js';
import { cleanupVoiceMember } from './voice.js';

export function handleLeaveSession(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  // Remove from voice chat if active
  cleanupVoiceMember(sessionId, participantId);

  // Clear any SOS they had raised — leaving is an explicit "I'm fine, I'm out".
  sessionStore.clearSos(sessionId, participantId);

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

  // An explicit leave is intentional and permanent, so the participant is
  // removed outright — unlike a disconnect, which only marks them offline so
  // reconnect + replay still works. Without this the store never sheds
  // participants, `participants.size` never reaches zero, and cleanup()'s
  // empty-session branch is unreachable: every session lives its full TTL
  // holding everyone who ever joined.
  sessionStore.removeParticipant(sessionId, participantId);

  // Unbind connection so handleDisconnect doesn't double-fire
  releaseConnection(conn);
  conn.sessionId = null;
  conn.participantId = null;

  // Close the WebSocket
  conn.ws.close(1000, 'Left session');
}
