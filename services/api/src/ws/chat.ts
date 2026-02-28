// CHAT_MESSAGE handler: validate, push event, broadcast.

import type { ValidatedChatMessagePayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

export function handleChatMessage(conn: ConnState, payload: ValidatedChatMessagePayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  // Update last seen on any activity
  participant.lastSeenTs = Date.now();

  // Push event and broadcast
  const event = sessionStore.pushEvent(sessionId, 'CHAT_MESSAGE', {
    participantId,
    displayName: participant.displayName,
    text: payload.text,
  });

  if (event) {
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
