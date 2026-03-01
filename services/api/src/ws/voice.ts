// VOICE_JOIN / VOICE_LEAVE / VOICE_SIGNAL handlers.
// Voice messages are EPHEMERAL — they are NOT emitted as EVENT,
// NOT stored in the event ring buffer, and NOT replayed on reconnect.
// Clients must re-join voice by sending VOICE_JOIN after WELCOME/SNAPSHOT.

import type { ValidatedVoiceSignalPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession, getSessionConnections } from './handler.js';
import { sessionStore } from '../state/session-store.js';

/** Maximum payload sizes for signaling data. */
const MAX_SDP_BYTES = 40 * 1024; // 40 KB for offer/answer
const MAX_ICE_BYTES = 8 * 1024; // 8 KB for ICE candidates

function sendError(conn: ConnState, message: string): void {
  sendJson(conn.ws, { type: 'ERROR', payload: { code: 'BAD_MESSAGE', message } });
}

export function handleVoiceJoin(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  session.voiceMembers.add(participantId);

  // Broadcast VOICE_STATE to all session participants
  broadcastToSession(sessionId, {
    type: 'VOICE_STATE',
    payload: { participantId, state: 'joined' },
  });
}

export function handleVoiceLeave(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  session.voiceMembers.delete(participantId);

  // Broadcast VOICE_STATE to all session participants
  broadcastToSession(sessionId, {
    type: 'VOICE_STATE',
    payload: { participantId, state: 'left' },
  });
}

export function handleVoiceSignal(conn: ConnState, payload: ValidatedVoiceSignalPayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Sender must be in voiceMembers
  if (!session.voiceMembers.has(participantId)) {
    sendError(conn, 'You must VOICE_JOIN before sending signals');
    return;
  }

  const { toParticipantId, signalType, data } = payload;

  // Recipient must be in the same session
  const recipient = sessionStore.getParticipant(sessionId, toParticipantId);
  if (!recipient) {
    sendError(conn, 'Recipient not found in session');
    return;
  }

  // Recipient must be in voiceMembers
  if (!session.voiceMembers.has(toParticipantId)) {
    sendError(conn, 'Recipient is not in voice chat');
    return;
  }

  // Enforce payload size limits (check serialized data size)
  const dataStr = JSON.stringify(data);
  const dataBytes = Buffer.byteLength(dataStr, 'utf-8');

  if ((signalType === 'offer' || signalType === 'answer') && dataBytes > MAX_SDP_BYTES) {
    sendError(conn, `SDP payload exceeds ${MAX_SDP_BYTES / 1024}KB limit`);
    return;
  }
  if (signalType === 'ice' && dataBytes > MAX_ICE_BYTES) {
    sendError(conn, `ICE payload exceeds ${MAX_ICE_BYTES / 1024}KB limit`);
    return;
  }

  // Forward signal only to the intended recipient
  const recipientConns = getSessionConnections(sessionId).filter(
    (c) => c.participantId === toParticipantId,
  );

  const forwardedMessage = {
    type: 'VOICE_SIGNAL',
    payload: {
      fromParticipantId: participantId,
      signalType,
      data,
    },
  };

  for (const recipientConn of recipientConns) {
    sendJson(recipientConn.ws, forwardedMessage);
  }
}

/** Remove a participant from voice when they leave or disconnect. */
export function cleanupVoiceMember(sessionId: string, participantId: string): void {
  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  if (session.voiceMembers.delete(participantId)) {
    // Broadcast VOICE_STATE left to remaining session participants
    broadcastToSession(sessionId, {
      type: 'VOICE_STATE',
      payload: { participantId, state: 'left' },
    });
  }
}
