// WebSocket connection handler and upgrade logic.

import { WebSocketServer, WebSocket } from 'ws';
import type { Server } from 'http';
import type { Logger } from 'pino';
import { v4 as uuid } from 'uuid';
import { dispatch } from './dispatcher.js';
import { sessionStore } from '../state/session-store.js';
import { cleanupVoiceMember } from './voice.js';
import { logger as rootLogger } from '../logging.js';
import { config } from '../config.js';

/** Per-connection state. `log` is a child logger bound with this connId. */
export interface ConnState {
  ws: WebSocket;
  sessionId: string | null;
  participantId: string | null;
  connId: string;
  /** Child logger bound with { connId } — grep by connId reconstructs the timeline. */
  log: Logger;
  /**
   * Heartbeat liveness. Set true on every pong; the sweep sets it false just
   * before pinging. A connection still false at the next sweep never answered
   * and is terminated.
   */
  isAlive: boolean;
}

const connections = new Map<string, ConnState>();

/**
 * sessionId → the connections bound to it.
 *
 * Without this index every broadcast scans *every* connection on the process,
 * so fan-out cost is O(total connections) per event rather than O(session
 * participants). With S sessions of P participants each sending 1 location
 * update/sec that is (S·P)² comparisons per second — quadratic in total users
 * for work that is inherently linear in session size.
 */
const sessionConnections = new Map<string, Set<ConnState>>();

/** Reverse lookup: get ConnState by connId */
export function getConnection(connId: string): ConnState | undefined {
  return connections.get(connId);
}

/** Bind a connection to a session. Called by the HELLO handler. */
export function bindConnectionToSession(conn: ConnState, sessionId: string): void {
  let set = sessionConnections.get(sessionId);
  if (!set) {
    set = new Set<ConnState>();
    sessionConnections.set(sessionId, set);
  }
  set.add(conn);
}

/** Unbind a connection from its session, dropping the index entry when empty. */
function unbindConnectionFromSession(conn: ConnState): void {
  if (!conn.sessionId) return;
  const set = sessionConnections.get(conn.sessionId);
  if (!set) return;
  set.delete(conn);
  if (set.size === 0) sessionConnections.delete(conn.sessionId);
}

/** Get all active connections for a session. */
export function getSessionConnections(sessionId: string): ConnState[] {
  const set = sessionConnections.get(sessionId);
  if (!set) return [];
  const result: ConnState[] = [];
  for (const conn of set) {
    if (conn.ws.readyState === WebSocket.OPEN) result.push(conn);
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
  const set = sessionConnections.get(sessionId);
  if (!set) return;
  const payload = JSON.stringify(message);
  for (const conn of set) {
    if (conn.ws.readyState === WebSocket.OPEN) {
      conn.ws.send(payload);
    }
  }
}

/** Total live connections (diagnostics + tests). */
export function connectionCount(): number {
  return connections.size;
}

let heartbeatTimer: ReturnType<typeof setInterval> | null = null;

/**
 * Ping every connection on an interval and terminate the ones that stopped
 * answering.
 *
 * Without this, a half-open TCP connection (device sleeps, carrier NAT drops
 * the flow, tunnel dies) never fires 'close'. The ConnState stays in the map
 * and the participant stays `online` forever — presence.ts cannot help,
 * because it only forces `offline` when `connId === null`, and `connId` is
 * cleared by the very close event that is never coming.
 */
function startHeartbeat(): void {
  if (heartbeatTimer) return;
  heartbeatTimer = setInterval(() => {
    for (const conn of connections.values()) {
      if (!conn.isAlive) {
        conn.log.debug('heartbeat timeout — terminating connection');
        conn.ws.terminate(); // fires 'close' → handleDisconnect
        continue;
      }
      conn.isAlive = false;
      try {
        conn.ws.ping();
      } catch {
        conn.ws.terminate();
      }
    }
  }, config.wsHeartbeatIntervalMs);
}

/** Stop the heartbeat sweep. Called on shutdown and by tests. */
export function stopHeartbeat(): void {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
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
      isAlive: true,
    };
    connections.set(connId, conn);
    conn.log.debug('ws connection opened');

    ws.on('pong', () => {
      conn.isAlive = true;
    });

    ws.on('message', (raw: Buffer | string) => {
      // Any inbound traffic proves liveness just as well as a pong.
      conn.isAlive = true;
      dispatch(conn, raw);
    });

    ws.on('close', () => {
      handleDisconnect(conn);
      unbindConnectionFromSession(conn);
      connections.delete(connId);
      conn.log.debug('ws connection closed');
    });

    ws.on('error', (err) => {
      conn.log.warn({ err }, 'ws connection error');
      handleDisconnect(conn);
      unbindConnectionFromSession(conn);
      connections.delete(connId);
    });
  });

  startHeartbeat();
  return wss;
}

/** Detach a connection from the session index without closing it. */
export function releaseConnection(conn: ConnState): void {
  unbindConnectionFromSession(conn);
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
