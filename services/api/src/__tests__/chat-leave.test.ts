import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket, type WebSocketServer } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket } from '../ws/handler.js';

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

async function createAndJoin(displayName = 'TestUser'): Promise<{
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

describe('CHAT_MESSAGE', () => {
  beforeEach(async () => {
    await startServer();
  });
  afterEach(async () => {
    await stopServer();
  });

  it('broadcasts CHAT_MESSAGE event to session', async () => {
    const { sessionId, participantId, token } = await createAndJoin('Alice');
    const ws = await connectWs();
    await doHello(ws, sessionId, participantId, token);

    ws.send(
      JSON.stringify({
        type: 'CHAT_MESSAGE',
        payload: { text: 'Hello everyone!' },
      }),
    );

    const event = (await receiveJson(ws)) as {
      type: string;
      payload: { kind: string; data: { participantId: string; displayName: string; text: string } };
    };
    expect(event.type).toBe('EVENT');
    expect(event.payload.kind).toBe('CHAT_MESSAGE');
    expect(event.payload.data.text).toBe('Hello everyone!');
    expect(event.payload.data.participantId).toBe(participantId);
    expect(event.payload.data.displayName).toBe('Alice');

    ws.close();
  });

  it('rejects CHAT_MESSAGE before HELLO', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'CHAT_MESSAGE',
        payload: { text: 'test' },
      }),
    );

    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('UNAUTHORIZED');

    ws.close();
  });

  it('rejects empty chat text', async () => {
    const ws = await connectWs();
    ws.send(
      JSON.stringify({
        type: 'CHAT_MESSAGE',
        payload: { text: '' },
      }),
    );

    const msg = (await receiveJson(ws)) as { type: string; payload: { code: string } };
    expect(msg.type).toBe('ERROR');
    expect(msg.payload.code).toBe('BAD_MESSAGE');

    ws.close();
  });

  it('broadcasts chat to other participants in the session', async () => {
    // Create session with Alice
    const alice = await createAndJoin('Alice');

    // Bob joins
    const bobRes = await app.inject({
      method: 'POST',
      url: '/sessions/join',
      payload: { joinCode: alice.joinCode, displayName: 'Bob' },
    });
    const bob = bobRes.json() as { sessionId: string; participantId: string; token: string };

    // Both connect via WS
    const wsAlice = await connectWs();
    await doHello(wsAlice, alice.sessionId, alice.participantId, alice.token);

    const wsBob = await connectWs();
    await doHello(wsBob, bob.sessionId, bob.participantId, bob.token);

    // Consume Bob's PARTICIPANT_JOINED on Alice's side
    await receiveJson(wsAlice);

    // Alice sends a chat message
    wsAlice.send(
      JSON.stringify({
        type: 'CHAT_MESSAGE',
        payload: { text: 'Hi Bob!' },
      }),
    );

    // Bob should receive it
    const bobMsg = (await receiveJson(wsBob)) as {
      type: string;
      payload: { kind: string; data: { text: string; displayName: string } };
    };
    expect(bobMsg.type).toBe('EVENT');
    expect(bobMsg.payload.kind).toBe('CHAT_MESSAGE');
    expect(bobMsg.payload.data.text).toBe('Hi Bob!');
    expect(bobMsg.payload.data.displayName).toBe('Alice');

    wsAlice.close();
    wsBob.close();
  });
});

describe('LEAVE_SESSION', () => {
  beforeEach(async () => {
    await startServer();
  });
  afterEach(async () => {
    await stopServer();
  });

  it('broadcasts PARTICIPANT_LEFT and closes connection', async () => {
    const alice = await createAndJoin('Alice');
    const bobRes = await app.inject({
      method: 'POST',
      url: '/sessions/join',
      payload: { joinCode: alice.joinCode, displayName: 'Bob' },
    });
    const bob = bobRes.json() as { sessionId: string; participantId: string; token: string };

    const wsAlice = await connectWs();
    await doHello(wsAlice, alice.sessionId, alice.participantId, alice.token);

    const wsBob = await connectWs();

    // Attach Alice's collector for BOTH broadcasts (Bob's PARTICIPANT_JOINED,
    // then PARTICIPANT_LEFT) BEFORE Bob acts — otherwise a message emitted in
    // the gap between awaits is dropped (EventEmitter doesn't buffer) and the
    // test hangs until timeout.
    const aliceEvents = collectMessages(wsAlice, 2);

    await doHello(wsBob, bob.sessionId, bob.participantId, bob.token);
    // Bob leaves
    wsBob.send(JSON.stringify({ type: 'LEAVE_SESSION', payload: {} }));

    // Second event on Alice's socket is Bob's PARTICIPANT_LEFT.
    const [, leftMsg] = (await aliceEvents) as [
      unknown,
      { type: string; payload: { kind: string; data: { participantId: string } } },
    ];
    expect(leftMsg.type).toBe('EVENT');
    expect(leftMsg.payload.kind).toBe('PARTICIPANT_LEFT');
    expect(leftMsg.payload.data.participantId).toBe(bob.participantId);

    // Bob's WS should close
    await new Promise<void>((resolve) => {
      if (wsBob.readyState === WebSocket.CLOSED) {
        resolve();
      } else {
        wsBob.on('close', () => resolve());
      }
    });

    wsAlice.close();
  });
});

describe('GET /sessions/:sessionId', () => {
  beforeEach(async () => {
    await startServer();
  });
  afterEach(async () => {
    await stopServer();
  });

  it('returns session info', async () => {
    const { sessionId, joinCode } = await createAndJoin('Alice');

    const res = await app.inject({
      method: 'GET',
      url: `/sessions/${sessionId}`,
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.sessionId).toBe(sessionId);
    expect(body.joinCode).toBe(joinCode);
    expect(body.participantCount).toBe(1);
    expect(body.participants).toHaveLength(1);
    expect(body.participants[0].displayName).toBe('Alice');
  });

  it('returns 404 for unknown session', async () => {
    const res = await app.inject({
      method: 'GET',
      url: '/sessions/nonexistent-id',
    });
    expect(res.statusCode).toBe(404);
  });
});
