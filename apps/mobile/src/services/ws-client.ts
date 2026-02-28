// WebSocket client: connect, HELLO handshake, send messages, receive events.

import { WS_URL } from '../utils/constants';
import { useSessionStore } from '../state/session-store';

type MessageHandler = (msg: unknown) => void;

let ws: WebSocket | null = null;
let messageHandlers: MessageHandler[] = [];

export function connectWs(
  sessionId: string,
  participantId: string,
  token: string,
  lastEventId: number | null,
): void {
  if (ws) {
    ws.close();
  }

  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
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
    // Auto-reconnect after 2s
    setTimeout(() => {
      const store = useSessionStore.getState();
      if (store.sessionId && store.participantId && store.token) {
        connectWs(store.sessionId, store.participantId, store.token, store.lastEventId);
      }
    }, 2000);
  };

  ws.onerror = () => {
    ws?.close();
  };
}

export function disconnectWs(): void {
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
    case 'WELCOME':
      // Connection confirmed
      break;

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
      break;
    }
  }
}
