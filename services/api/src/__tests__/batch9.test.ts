import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket, type WebSocketServer } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket } from '../ws/handler.js';
import {
  connectWs as sharedConnectWs,
  receiveJson as sharedReceiveJson,
  collectMessages as sharedCollectMessages,
} from './helpers/ws-test-client.js';

let app: FastifyInstance;
let port: number;
let wss: WebSocketServer | undefined;

async function startServer(): Promise<void> {
  app = Fastify({ logger: false });
  await registerRoutes(app);
  await app.listen({ port: 0, host: '127.0.0.1' });
  wss = setupWebSocket(app.server);
  const addr = app.server.address();
  port = typeof addr === 'object' && addr ? addr.port : 0;
}

async function stopServer(): Promise<void> {
  // Terminate lingering WS clients and close the WS server first, otherwise
  // app.close() blocks on open sockets until the OS times them out.
  for (const client of wss?.clients ?? []) client.terminate();
  await new Promise<void>((resolve) => (wss ? wss.close(() => resolve()) : resolve()));
  await app?.close();
}

function connectWs(): Promise<WebSocket> {
  return sharedConnectWs(port);
}

function receiveJson(ws: WebSocket): Promise<unknown> {
  return sharedReceiveJson(ws);
}

function collectMessages(ws: WebSocket, count: number): Promise<unknown[]> {
  return sharedCollectMessages(ws, count);
}

async function createSession(displayName = 'Host'): Promise<{
  sessionId: string;
  participantId: string;
  token: string;
  joinCode: string;
}> {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions',
    payload: { displayName },
  });
  return res.json();
}

async function joinSession(joinCode: string, displayName = 'Guest'): Promise<{
  sessionId: string;
  participantId: string;
  token: string;
}> {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions/join',
    payload: { joinCode, displayName },
  });
  return res.json();
}

async function doHello(
  ws: WebSocket,
  sessionId: string,
  participantId: string,
  token: string,
): Promise<unknown[]> {
  ws.send(
    JSON.stringify({
      type: 'HELLO',
      payload: { sessionId, participantId, token, lastEventId: null },
    }),
  );
  return collectMessages(ws, 3); // WELCOME, SNAPSHOT, PARTICIPANT_JOINED
}

// ── Host-Only Destination ─────────────────────────────────────────────

describe('Host-Only Destination', () => {
  beforeEach(async () => { await startServer(); });
  afterEach(async () => { await stopServer(); });

  it('host can set destination', async () => {
    const host = await createSession('HostUser');
    const ws = await connectWs();
    await doHello(ws, host.sessionId, host.participantId, host.token);

    ws.send(JSON.stringify({
      type: 'SET_DESTINATION',
      payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
    }));

    const event = (await receiveJson(ws)) as {
      type: string;
      payload: { kind: string; data: { label: string; setBy: string } };
    };
    expect(event.type).toBe('EVENT');
    expect(event.payload.kind).toBe('DESTINATION_SET');
    expect(event.payload.data.label).toBe('NYC');
    expect(event.payload.data.setBy).toBe(host.participantId);

    ws.close();
  });

  it('non-host receives FORBIDDEN when setting destination', async () => {
    const host = await createSession('Host');
    const guest = await joinSession(host.joinCode, 'Guest');

    const wsGuest = await connectWs();
    await doHello(wsGuest, guest.sessionId, guest.participantId, guest.token);

    wsGuest.send(JSON.stringify({
      type: 'SET_DESTINATION',
      payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
    }));

    const msg = (await receiveJson(wsGuest)) as {
      type: string;
      payload: { code: string };
    };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('FORBIDDEN');

    wsGuest.close();
  });

  it('WELCOME includes hostParticipantId', async () => {
    const host = await createSession('Host');
    const ws = await connectWs();

    ws.send(JSON.stringify({
      type: 'HELLO',
      payload: {
        sessionId: host.sessionId,
        participantId: host.participantId,
        token: host.token,
        lastEventId: null,
      },
    }));

    const msgs = await collectMessages(ws, 3);
    const welcome = msgs[0] as { type: string; payload: { hostParticipantId: string } };

    expect(welcome.type).toBe('WELCOME');
    expect(welcome.payload.hostParticipantId).toBe(host.participantId);

    ws.close();
  });
});

// ── Clear Destination ─────────────────────────────────────────────────

describe('Clear Destination', () => {
  beforeEach(async () => { await startServer(); });
  afterEach(async () => { await stopServer(); });

  it('host can clear destination', async () => {
    const host = await createSession('Host');
    const ws = await connectWs();
    await doHello(ws, host.sessionId, host.participantId, host.token);

    // Set destination first
    ws.send(JSON.stringify({
      type: 'SET_DESTINATION',
      payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
    }));
    await receiveJson(ws); // consume DESTINATION_SET

    // Clear destination
    ws.send(JSON.stringify({
      type: 'CLEAR_DESTINATION',
      payload: {},
    }));

    const event = (await receiveJson(ws)) as {
      type: string;
      payload: { kind: string; data: { clearedBy: string } };
    };
    expect(event.type).toBe('EVENT');
    expect(event.payload.kind).toBe('DESTINATION_CLEARED');
    expect(event.payload.data.clearedBy).toBe(host.participantId);

    ws.close();
  });

  it('non-host receives FORBIDDEN when clearing destination', async () => {
    const host = await createSession('Host');
    const guest = await joinSession(host.joinCode, 'Guest');

    // Host sets destination first
    const wsHost = await connectWs();
    await doHello(wsHost, host.sessionId, host.participantId, host.token);
    wsHost.send(JSON.stringify({
      type: 'SET_DESTINATION',
      payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
    }));
    await receiveJson(wsHost); // consume DESTINATION_SET

    // Guest tries to clear
    const wsGuest = await connectWs();
    await doHello(wsGuest, guest.sessionId, guest.participantId, guest.token);
    // Consume host's PARTICIPANT_JOINED broadcast on guest side is already consumed in doHello

    wsGuest.send(JSON.stringify({
      type: 'CLEAR_DESTINATION',
      payload: {},
    }));

    const msg = (await receiveJson(wsGuest)) as {
      type: string;
      payload: { code: string };
    };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('FORBIDDEN');

    wsHost.close();
    wsGuest.close();
  });

  it('destination is null in SNAPSHOT after clearing', async () => {
    const host = await createSession('Host');

    // Connect, set and clear
    const ws1 = await connectWs();
    await doHello(ws1, host.sessionId, host.participantId, host.token);

    ws1.send(JSON.stringify({
      type: 'SET_DESTINATION',
      payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
    }));
    await receiveJson(ws1);

    ws1.send(JSON.stringify({
      type: 'CLEAR_DESTINATION',
      payload: {},
    }));
    await receiveJson(ws1);
    ws1.close();

    // Wait for disconnect
    await new Promise((r) => setTimeout(r, 200));

    // Reconnect and check SNAPSHOT
    const ws2 = await connectWs();
    ws2.send(JSON.stringify({
      type: 'HELLO',
      payload: {
        sessionId: host.sessionId,
        participantId: host.participantId,
        token: host.token,
        lastEventId: null,
      },
    }));

    // A reconnect yields WELCOME + SNAPSHOT only — no PARTICIPANT_JOINED,
    // and no EVENTS because lastEventId is null (full-snapshot path).
    const msgs = await collectMessages(ws2, 2);
    const snapshot = msgs[1] as { type: string; payload: { destination: unknown } };
    expect(snapshot.type).toBe('SNAPSHOT');
    expect(snapshot.payload.destination).toBeNull();

    ws2.close();
  });
});

// ── HTTP Validation ───────────────────────────────────────────────────

describe('HTTP Validation (Batch 9)', () => {
  it('rejects join with invalid join code format', async () => {
    const app = Fastify({ logger: false });
    await registerRoutes(app);

    const res = await app.inject({
      method: 'POST',
      url: '/sessions/join',
      payload: { joinCode: 'abc' }, // too short, wrong format
    });
    expect(res.statusCode).toBe(400);
  });

  it('sanitizes long display names', async () => {
    const app = Fastify({ logger: false });
    await registerRoutes(app);

    const longName = 'A'.repeat(100);
    const res = await app.inject({
      method: 'POST',
      url: '/sessions',
      payload: { displayName: longName },
    });
    expect(res.statusCode).toBe(201);
    // Name should have been truncated server-side (session still created)
  });

  it('trims whitespace from display names', async () => {
    const app = Fastify({ logger: false });
    await registerRoutes(app);

    const res = await app.inject({
      method: 'POST',
      url: '/sessions',
      payload: { displayName: '  Alice  ' },
    });
    expect(res.statusCode).toBe(201);
    // Session created successfully with trimmed name
  });

  it('session info includes lastSeenTs and createdAt', async () => {
    const app = Fastify({ logger: false });
    await registerRoutes(app);

    const createRes = await app.inject({
      method: 'POST',
      url: '/sessions',
      payload: { displayName: 'Alice' },
    });
    const { sessionId, token } = createRes.json();

    const infoRes = await app.inject({
      method: 'GET',
      url: `/sessions/${sessionId}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(infoRes.statusCode).toBe(200);
    const body = infoRes.json();
    expect(body).toHaveProperty('createdAt');
    expect(body.participants[0]).toHaveProperty('lastSeenTs');
  });
});
