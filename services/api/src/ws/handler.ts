// WebSocket connection handler and upgrade logic.

import { WebSocketServer, WebSocket } from 'ws';
import type { Server } from 'http';
import type { Logger } from 'pino';
import { v4 as uuid } from 'uuid';
import { dispatch } from './dispatcher.js';
import { sessionStore } from '../state/session-store.js';
import { cleanupVoiceMember } from './voice.js';
import { logger as rootLogger } from '../logging.js';

/** Per-connection state. `log` is a child logger bound with this connId. */
export interface ConnState {
  ws: WebSocket;
  sessionId: string | null;
  participantId: string | null;
  connId: string;
  /** Child logger bound with { connId } — grep by connId reconstructs the timeline. */
  log: Logger;
}

const connections = new Map<string, ConnState>();

/** Reverse lookup: get ConnState by connId */
export function getConnection(connId: string): ConnState | undefined {
  return connections.get(connId);
}

/** Get all active connections for a session. */
export function getSessionConnections(sessionId: string): ConnState[] {
  const result: ConnState[] = [];
  for (const conn of connections.values()) {
    if (conn.sessionId === sessionId && conn.ws.readyState === WebSocket.OPEN) {
      result.push(conn);
    }
  }
  return result;
}

/** Send a JSON message to a specific WebSocket. */
export function sendJson(ws: WebSocket, message: unknown): void {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(message));
  }
}

/** Broadcast a JSON message to all connections in a session. */
export function broadcastToSession(sessionId: string, message: unknown): void {
  const payload = JSON.stringify(message);
  for (const conn of connections.values()) {
    if (conn.sessionId === sessionId && conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(payload);
    }
  }
}

export function setupWebSocket(server: Server): WebSocketServer {
  const wss = new WebSocketServer({ server });

  wss.on('connection', (ws: WebSocket) => {
    const connId = uuid();
    const conn: ConnState = {
      ws,
      sessionId: null,
      participantId: null,
      connId,
      log: rootLogger.child({ connId }),
    };
    connections.set(connId, conn);
    conn.log.debug('ws connection opened');

    ws.on('message', (raw: Buffer | string) => {
      dispatch(conn, raw);
    });

    ws.on('close', () => {
      handleDisconnect(conn);
      connections.delete(connId);
      conn.log.debug('ws connection closed');
    });

    ws.on('error', (err) => {
      conn.log.warn({ err }, 'ws connection error');
      handleDisconnect(conn);
      connections.delete(connId);
    });
  });

  return wss;
}

function handleDisconnect(conn: ConnState): void {
  if (!conn.sessionId || !conn.participantId) return;

  // Remove from voice chat if active
  cleanupVoiceMember(conn.sessionId, conn.participantId);

  const participant = sessionStore.getParticipant(conn.sessionId, conn.participantId);
  if (participant && participant.connId === conn.connId) {
    participant.connId = null;
    participant.status = 'offline';

    // Broadcast PARTICIPANT_LEFT event
    const event = sessionStore.pushEvent(conn.sessionId, 'PARTICIPANT_LEFT', {
      participantId: conn.participantId,
    });

    if (event) {
      broadcastToSession(conn.sessionId, { type: 'EVENT', payload: event });
    }
  }
}
