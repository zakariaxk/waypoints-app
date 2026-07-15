// WS message dispatcher: parse → validate → route to handler.

import type { ErrorMessage } from '@waypoints/shared';
import { clientMessageSchema } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson } from './handler.js';
import { logInboundMessage, logClientError } from '../logging.js';
import { handleHello } from './handshake.js';
import { handleLocUpdate } from './location.js';
import { handleSetDestination, handleClearDestination } from './destination.js';
import { handleChatMessage } from './chat.js';
import { handleLeaveSession } from './leave.js';
import { handleVoiceJoin, handleVoiceLeave, handleVoiceSignal } from './voice.js';

export function dispatch(conn: ConnState, raw: Buffer | string): void {
  // 1. Parse JSON
  let parsed: unknown;
  try {
    parsed = JSON.parse(typeof raw === 'string' ? raw : raw.toString('utf-8'));
  } catch {
    sendError(conn, 'BAD_MESSAGE', 'Invalid JSON');
    return;
  }

  // 2. Validate against schema
  const result = clientMessageSchema.safeParse(parsed);
  if (!result.success) {
    const issues = result.error.issues.map((i) => i.message).join('; ');
    sendError(conn, 'BAD_MESSAGE', `Validation failed: ${issues}`);
    return;
  }

  const message = result.data;

  // Log routing metadata only — never the payload (no coordinates/chat text).
  logInboundMessage(conn.log, conn, message);

  // 3. HELLO is allowed before handshake; others require it
  if (message.type === 'HELLO') {
    handleHello(conn, message.payload);
    return;
  }

  // All other messages require an authenticated connection
  if (!conn.sessionId || !conn.participantId) {
    sendError(conn, 'UNAUTHORIZED', 'Send HELLO first');
    return;
  }

  // 4. Route by type
  switch (message.type) {
    case 'LOC_UPDATE':
      handleLocUpdate(conn, message.payload);
      break;
    case 'SET_DESTINATION':
      handleSetDestination(conn, message.payload);
      break;
    case 'CLEAR_DESTINATION':
      handleClearDestination(conn);
      break;
    case 'CHAT_MESSAGE':
      handleChatMessage(conn, message.payload);
      break;
    case 'LEAVE_SESSION':
      handleLeaveSession(conn);
      break;
    case 'VOICE_JOIN':
      handleVoiceJoin(conn);
      break;
    case 'VOICE_LEAVE':
      handleVoiceLeave(conn);
      break;
    case 'VOICE_SIGNAL':
      handleVoiceSignal(conn, message.payload);
      break;
    default:
      sendError(conn, 'BAD_MESSAGE', `Unknown message type`);
  }
}

function sendError(conn: ConnState, code: ErrorMessage['payload']['code'], message: string): void {
  logClientError(conn.log, conn, code, message);
  sendJson(conn.ws, { type: 'ERROR', payload: { code, message } });
}
