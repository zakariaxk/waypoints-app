// WebSocket client: connect, HELLO handshake, send messages, receive events.

import { WS_URL } from '../utils/constants';
import { useSessionStore } from '../state/session-store';

type MessageHandler = (msg: unknown) => void;

let ws: WebSocket | null = null;
let messageHandlers: MessageHandler[] = [];
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let intentionalClose = false;
let reconnectAttempts = 0;
let sessionInvalidated = false;

/** Exponential backoff: 1s, 2s, 4s, 8s max */
function getReconnectDelay(): number {
  const base = 1000;
  const delay = Math.min(base * 2 ** reconnectAttempts, 8000);
  reconnectAttempts++;
  return delay;
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
  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    reconnectAttempts = 0; // reset backoff on successful connect
    sendJson({
      type: 'HELLO',
      payload: { sessionId, participantId, token, lastEventId },
    });
    useSessionStore.getState().setConnected(true);
  };

  ws.onmessage = (event) => {
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

function handleServerMessage(msg: { type: string; payload: Record<string, unknown> }): void {
  const store = useSessionStore.getState();

  switch (msg.type) {
    case 'WELCOME': {
      // Extract hostParticipantId from WELCOME
      const welcome = msg.payload as { hostParticipantId?: string };
      if (welcome.hostParticipantId) {
        store.setHostParticipantId(welcome.hostParticipantId);
      }
      break;
    }

    case 'SNAPSHOT': {
      const payload = msg.payload as {
        latestEventId: number;
        destination: { lat: number; lng: number; label: string | null } | null;
        participants: Array<{
          participantId: string;
          displayName: string | null;
          lastLocation: { lat: number; lng: number } | null;
          status: string;
          lastSeenTs: number;
        }>;
      };
      store.applySnapshot(payload);
      break;
    }

    case 'EVENTS': {
      const payload = msg.payload as { events: ServerEvent[] };
      for (const event of payload.events) {
        store.applyEvent(event);
      }
      break;
    }

    case 'EVENT': {
      const event = msg.payload as ServerEvent;
      store.applyEvent(event);
      break;
    }

    case 'ERROR': {
      const payload = msg.payload as { code: string; message: string };
      console.warn(`[WS ERROR] ${payload.code}: ${payload.message}`);

      // Fatal errors — session no longer exists on server
      const FATAL_CODES = ['NOT_IN_SESSION', 'SESSION_NOT_FOUND', 'INVALID_TOKEN'];
      if (FATAL_CODES.includes(payload.code)) {
        sessionInvalidated = true;
        disconnectWs();
      }
      break;
    }
  }
}
