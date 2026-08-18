// WebSocket client: connect, HELLO handshake, send messages, receive events.

import { WS_URL, WS_RECEIVE_TIMEOUT_MS } from '../utils/constants';
import { useSessionStore } from '../state/session-store';

type MessageHandler = (msg: unknown) => void;

/** How the connection is doing, for UI that needs to tell these apart. */
export type ConnectionPhase = 'connecting' | 'connected' | 'reconnecting' | 'invalid';

let ws: WebSocket | null = null;
let messageHandlers: MessageHandler[] = [];
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let receiveWatchdog: ReturnType<typeof setTimeout> | null = null;
let intentionalClose = false;
let reconnectAttempts = 0;
let sessionInvalidated = false;
/** True once WELCOME has arrived on the current connection. */
let helloCompleted = false;

/** Exponential backoff: 1s, 2s, 4s, 8s max */
function getReconnectDelay(): number {
  const base = 1000;
  const delay = Math.min(base * 2 ** reconnectAttempts, 8000);
  reconnectAttempts++;
  return delay;
}

/**
 * The server pings every WS_HEARTBEAT_INTERVAL_MS and terminates connections
 * that stop ponging. React Native's WebSocket answers pings at the protocol
 * level but does not surface them to JS, so the client cannot observe the
 * heartbeat directly. Instead it watches for *any* inbound traffic: if nothing
 * arrives for WS_RECEIVE_TIMEOUT_MS the socket is treated as dead and closed,
 * which drives the normal reconnect + snapshot/replay path.
 *
 * A fully idle session (nobody moving, nobody chatting) can trip this. That
 * costs one cheap reconnect and is strictly better than showing a live map
 * backed by a socket that died twenty minutes ago.
 */
function armReceiveWatchdog(): void {
  if (receiveWatchdog) clearTimeout(receiveWatchdog);
  receiveWatchdog = setTimeout(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.close(4000, 'receive timeout');
    }
  }, WS_RECEIVE_TIMEOUT_MS);
}

function clearReceiveWatchdog(): void {
  if (receiveWatchdog) {
    clearTimeout(receiveWatchdog);
    receiveWatchdog = null;
  }
}

export function connectWs(
  sessionId: string,
  participantId: string,
  token: string,
  lastEventId: number | null,
): void {
  if (ws) {
    intentionalClose = true;
    ws.close();
  }

  intentionalClose = false;
  sessionInvalidated = false;
  helloCompleted = false;
  ws = new WebSocket(WS_URL);

  // A live event arriving out of sequence means we missed something the
  // snapshot/replay path is the only thing that can fill. Drop the socket so
  // the reconnect re-runs HELLO with our current lastEventId.
  useSessionStore.getState().setResyncHandler(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.close(4001, 'event gap — resync');
    }
  });

  ws.onopen = () => {
    reconnectAttempts = 0; // reset backoff on successful connect
    sendJson({
      type: 'HELLO',
      payload: { sessionId, participantId, token, lastEventId },
    });
    useSessionStore.getState().setConnected(true);
    armReceiveWatchdog();
  };

  ws.onmessage = (event) => {
    armReceiveWatchdog();
    try {
      const msg = JSON.parse(event.data as string);
      handleServerMessage(msg);
      for (const handler of messageHandlers) {
        handler(msg);
      }
    } catch {
      // Ignore malformed server messages
    }
  };

  ws.onclose = () => {
    clearReceiveWatchdog();
    useSessionStore.getState().setConnected(false);
    ws = null;

    // Auto-reconnect unless intentionally closed or session is gone
    if (!intentionalClose && !sessionInvalidated) {
      if (reconnectTimer) clearTimeout(reconnectTimer);
      const delay = getReconnectDelay();
      reconnectTimer = setTimeout(() => {
        const store = useSessionStore.getState();
        if (store.sessionId && store.participantId && store.token) {
          store.incrementReconnectCount();
          connectWs(store.sessionId, store.participantId, store.token, store.lastEventId);
        }
      }, delay);
    }
  };

  ws.onerror = () => {
    ws?.close();
  };
}

export function disconnectWs(): void {
  intentionalClose = true;
  sessionInvalidated = false;
  reconnectAttempts = 0;
  clearReceiveWatchdog();
  useSessionStore.getState().setResyncHandler(null);
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
  if (ws) {
    ws.close();
    ws = null;
  }
}

export function sendJson(data: unknown): void {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(data));
  }
}

export function sendLocUpdate(payload: {
  seq: number;
  lat: number;
  lng: number;
  speed: number | null;
  heading: number | null;
  accuracy: number | null;
  ts: number;
  battery?: number | null;
  charging?: boolean | null;
}): void {
  sendJson({ type: 'LOC_UPDATE', payload });
}

export function sendSetDestination(lat: number, lng: number, label: string | null): void {
  sendJson({ type: 'SET_DESTINATION', payload: { lat, lng, label } });
}

export function sendClearDestination(): void {
  sendJson({ type: 'CLEAR_DESTINATION', payload: {} });
}

export function sendChatMessage(text: string): void {
  sendJson({ type: 'CHAT_MESSAGE', payload: { text } });
}

export function sendLeaveSession(): void {
  sendJson({ type: 'LEAVE_SESSION', payload: {} });
  disconnectWs();
}

// ─── Safety (Phase 3) ───

export function sendRaiseSos(note?: string): void {
  const payload = note && note.trim() ? { note: note.trim().slice(0, 140) } : {};
  sendJson({ type: 'RAISE_SOS', payload });
}

export function sendClearSos(): void {
  sendJson({ type: 'CLEAR_SOS', payload: {} });
}

export function sendArrivalPing(): void {
  sendJson({ type: 'ARRIVAL_PING', payload: {} });
}

export function isSessionInvalidated(): boolean {
  return sessionInvalidated;
}

export function onMessage(handler: MessageHandler): () => void {
  messageHandlers.push(handler);
  return () => {
    messageHandlers = messageHandlers.filter((h) => h !== handler);
  };
}

// ─── Internal message handling ───

interface ServerEvent {
  eventId: number;
  kind: string;
  data: Record<string, unknown>;
  ts: number;
}

/**
 * Errors that mean reconnecting will never succeed. Retrying past these
 * produces an infinite connect → reject → backoff loop with nothing shown to
 * the user, so they stop the loop and surface a rejoin prompt instead.
 */
const FATAL_CODES = ['NOT_IN_SESSION', 'SESSION_NOT_FOUND', 'INVALID_TOKEN'];

/**
 * `UNAUTHORIZED` is overloaded by the protocol: the handshake sends it for a
 * bad token (fatal — retrying can never work), and the dispatcher sends it for
 * "send HELLO first" (benign — a message raced the handshake). Only the
 * pre-WELCOME case is fatal.
 */
function isFatalError(code: string): boolean {
  if (code === 'UNAUTHORIZED') return !helloCompleted;
  return FATAL_CODES.indexOf(code) !== -1;
}

function handleServerMessage(msg: { type: string; payload: Record<string, unknown> }): void {
  const store = useSessionStore.getState();

  switch (msg.type) {
    case 'WELCOME': {
      helloCompleted = true;
      const welcome = msg.payload as { hostParticipantId?: string };
      if (welcome.hostParticipantId) {
        store.setHostParticipantId(welcome.hostParticipantId);
      }
      break;
    }

    case 'SNAPSHOT': {
      // Cast intentionally mirrors the SNAPSHOT shape in docs/WS-PROTOCOL.md,
      // including the Phase 3 fields (battery/charging/arrived/sos + activeSos).
      const payload = msg.payload as unknown as Parameters<typeof store.applySnapshot>[0];
      store.applySnapshot(payload);
      break;
    }

    case 'EVENTS': {
      // Server-computed replay batch — applied unconditionally, in order.
      const payload = msg.payload as unknown as { events: ServerEvent[] };
      store.applyEvents(payload.events ?? []);
      break;
    }

    case 'EVENT': {
      const event = msg.payload as unknown as ServerEvent;
      store.applyEvent(event);
      break;
    }

    case 'ERROR': {
      const payload = msg.payload as { code: string; message: string };
      console.warn(`[WS ERROR] ${payload.code}: ${payload.message}`);

      if (isFatalError(payload.code)) {
        sessionInvalidated = true;
        disconnectWs();
      }
      break;
    }

    case 'VOICE_STATE': {
      const vsPayload = msg.payload as { participantId: string; state: 'joined' | 'left' };
      if (vsPayload.state === 'joined') {
        store.addVoiceMember(vsPayload.participantId);
      } else {
        store.removeVoiceMember(vsPayload.participantId);
      }
      break;
    }

    // VOICE_SIGNAL is handled by voice service listeners, not the store
  }
}
