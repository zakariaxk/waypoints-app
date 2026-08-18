// CHAT_MESSAGE handler: validate, rate limit, push event, broadcast.

import type { ValidatedChatMessagePayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { broadcastToSession, sendJson } from './handler.js';
import { sessionStore } from '../state/session-store.js';
import { config } from '../config.js';

export function handleChatMessage(conn: ConnState, payload: ValidatedChatMessagePayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  // Fixed-window rate limit per participant.
  //
  // Chat is told about being limited rather than silently dropped, unlike
  // LOC_UPDATE: a dropped location is replaced by the next one a second later,
  // but a dropped message is gone and the sender would never know.
  const now = Date.now();
  if (now - participant.chatWindowStartTs >= config.chatRateLimitWindowMs) {
    participant.chatWindowStartTs = now;
    participant.chatWindowCount = 0;
  }
  if (participant.chatWindowCount >= config.chatRateLimitCount) {
    sendJson(conn.ws, {
      type: 'ERROR',
      payload: {
        code: 'RATE_LIMITED',
        message: `Too many messages — max ${config.chatRateLimitCount} per ${
          config.chatRateLimitWindowMs / 1000
        }s`,
      },
    });
    return;
  }
  participant.chatWindowCount += 1;

  // Update last seen on any activity
  participant.lastSeenTs = now;

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
