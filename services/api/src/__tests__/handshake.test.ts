import { describe, it, expect, beforeEach, afterEach, afterAll } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket } from '../ws/handler.js';

let app: FastifyInstance;
let port: number;

async function startServer(): Promise<void> {
  app = Fastify({ logger: false });
  await registerRoutes(app);
  await app.listen({ port: 0, host: '127.0.0.1' });
  setupWebSocket(app.server);
  const addr = app.server.address();
  port = typeof addr === 'object' && addr ? addr.port : 0;
}

async function stopServer(): Promise<void> {
  await app?.close();
}

function connectWs(): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    ws.on('open', () => resolve(ws));
    ws.on('error', reject);
  });
}

function receiveJson(ws: WebSocket): Promise<unknown> {
  return new Promise((resolve) => {
    ws.once('message', (data) => {
      resolve(JSON.parse(data.toString()));
    });
  });
}

/** Collect N messages from WS */
function collectMessages(ws: WebSocket, count: number): Promise<unknown[]> {
  return new Promise((resolve) => {
    const msgs: unknown[] = [];
    const handler = (data: Buffer | string) => {
      msgs.push(JSON.parse(data.toString()));
      if (msgs.length >= count) {
        ws.off('message', handler);
        resolve(msgs);
      }
    };
    ws.on('message', handler);
  });
}

async function createAndJoin(): Promise<{
  sessionId: string;
  participantId: string;
  token: string;
  joinCode: string;
}> {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions',
    payload: { displayName: 'TestUser' },
  });
  return res.json();
}

describe('WebSocket Protocol', () => {
  beforeEach(async () => {
    await startServer();
  });

  afterEach(async () => {
    await stopServer();
  });

  it('rejects invalid JSON with ERROR', async () => {
    const ws = await connectWs();
    ws.send('not valid json');
    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('BAD_MESSAGE');
    ws.close();
  });

  it('rejects unknown message type with ERROR', async () => {
    const ws = await connectWs();
    ws.send(JSON.stringify({ type: 'UNKNOWN', payload: {} }));
    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('BAD_MESSAGE');
    ws.close();
  });

  it('rejects non-HELLO messages before handshake', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'LOC_UPDATE',
        payload: { seq: 1, lat: 0, lng: 0, speed: null, heading: null, accuracy: null, ts: 1 },
      }),
    );
    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('UNAUTHORIZED');
    ws.close();
  });

  it('HELLO with invalid session returns NOT_IN_SESSION', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: {
          sessionId: 'fake-session',
          participantId: 'fake-participant',
          token: 'fake-token',
          lastEventId: null,
        },
      }),
    );
    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('NOT_IN_SESSION');
    ws.close();
  });

  it('HELLO with bad token returns UNAUTHORIZED', async () => {
    const { sessionId, participantId } = await createAndJoin();
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: {
          sessionId,
          participantId,
          token: 'wrong-token',
          lastEventId: null,
        },
      }),
    );
    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('UNAUTHORIZED');
    ws.close();
  });

  it('successful HELLO returns WELCOME + SNAPSHOT', async () => {
    const { sessionId, participantId, token } = await createAndJoin();
    const ws = await connectWs();

    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: { sessionId, participantId, token, lastEventId: null },
      }),
    );

    const msgs = await collectMessages(ws, 3); // WELCOME, SNAPSHOT, EVENT (PARTICIPANT_JOINED)
    const [welcome, snapshot] = msgs as [
      { type: string; payload: { connId: string; sessionId: string } },
      { type: string; payload: { latestEventId: number; participants: unknown[] } },
    ];

    expect(welcome.type).toBe('WELCOME');
    expect(welcome.payload.sessionId).toBe(sessionId);
    expect(welcome.payload).toHaveProperty('connId');

    expect(snapshot.type).toBe('SNAPSHOT');
    expect(snapshot.payload).toHaveProperty('latestEventId');
    expect(snapshot.payload).toHaveProperty('participants');

    ws.close();
  });

  it('LOC_UPDATE after HELLO broadcasts LOCATION_UPDATED event', async () => {
    const { sessionId, participantId, token } = await createAndJoin();
    const ws = await connectWs();

    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: { sessionId, participantId, token, lastEventId: null },
      }),
    );

    // Consume WELCOME + SNAPSHOT + PARTICIPANT_JOINED
    await collectMessages(ws, 3);

    // Send location update
    ws.send(
      JSON.stringify({
        type: 'LOC_UPDATE',
        payload: {
          seq: 1,
          lat: 37.7749,
          lng: -122.4194,
          speed: 5.0,
          heading: 90,
          accuracy: 10,
          ts: Date.now(),
        },
      }),
    );

    const event = (await receiveJson(ws)) as {
      type: string;
      payload: { kind: string; data: { lat: number } };
    };
    expect(event.type).toBe('EVENT');
    expect(event.payload.kind).toBe('LOCATION_UPDATED');
    expect(event.payload.data.lat).toBeCloseTo(37.7749);

    ws.close();
  });

  it('SET_DESTINATION broadcasts DESTINATION_SET event', async () => {
    const { sessionId, participantId, token } = await createAndJoin();
    const ws = await connectWs();

    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: { sessionId, participantId, token, lastEventId: null },
      }),
    );

    await collectMessages(ws, 3);

    ws.send(
      JSON.stringify({
        type: 'SET_DESTINATION',
        payload: { lat: 40.7128, lng: -74.006, label: 'NYC' },
      }),
    );

    const event = (await receiveJson(ws)) as {
      type: string;
      payload: { kind: string; data: { label: string } };
    };
    expect(event.type).toBe('EVENT');
    expect(event.payload.kind).toBe('DESTINATION_SET');
    expect(event.payload.data.label).toBe('NYC');

    ws.close();
  });
});

describe('Reconnect Replay', () => {
  beforeEach(async () => {
    await startServer();
  });

  afterEach(async () => {
    await stopServer();
  });

  it('replays missed events on reconnect with lastEventId', async () => {
    const { sessionId, participantId, token } = await createAndJoin();

    // First connection: generate some events
    const ws1 = await connectWs();
    ws1.send(
      JSON.stringify({
        type: 'HELLO',
        payload: { sessionId, participantId, token, lastEventId: null },
      }),
    );
    const initialMsgs = await collectMessages(ws1, 3);
    const snapshot = initialMsgs[1] as { payload: { latestEventId: number } };

    // Send a destination update to create an additional event
    ws1.send(
      JSON.stringify({
        type: 'SET_DESTINATION',
        payload: { lat: 1, lng: 2, label: 'Test' },
      }),
    );
    const destEvent = (await receiveJson(ws1)) as { payload: { eventId: number } };
    ws1.close();

    // Wait for disconnect to register
    await new Promise((r) => setTimeout(r, 200));

    // Second connection: reconnect with lastEventId before the destination event
    const ws2 = await connectWs();
    const lastEventIdBeforeDest = destEvent.payload.eventId - 1;

    ws2.send(
      JSON.stringify({
        type: 'HELLO',
        payload: { sessionId, participantId, token, lastEventId: lastEventIdBeforeDest },
      }),
    );

    // Should get WELCOME, SNAPSHOT, EVENTS (with missed events), then PARTICIPANT_JOINED
    const reconnectMsgs = await collectMessages(ws2, 4);
    const types = (reconnectMsgs as { type: string }[]).map((m) => m.type);

    expect(types[0]).toBe('WELCOME');
    expect(types[1]).toBe('SNAPSHOT');
    expect(types[2]).toBe('EVENTS');

    const eventsMsg = reconnectMsgs[2] as {
      payload: { events: { kind: string }[] };
    };
    expect(eventsMsg.payload.events.length).toBeGreaterThan(0);

    ws2.close();
  });
});
