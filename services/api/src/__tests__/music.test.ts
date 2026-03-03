import { describe, it, expect, beforeEach, afterEach } from 'vitest';
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

function collectMessages(ws: WebSocket, count: number, timeoutMs = 2000): Promise<unknown[]> {
  return new Promise((resolve) => {
    const msgs: unknown[] = [];
    const timer = setTimeout(() => {
      ws.off('message', handler);
      resolve(msgs);
    }, timeoutMs);
    const handler = (data: Buffer | string) => {
      msgs.push(JSON.parse(data.toString()));
      if (msgs.length >= count) {
        clearTimeout(timer);
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

async function joinWithCode(
  joinCode: string,
  displayName = 'Joiner',
): Promise<{ sessionId: string; participantId: string; token: string }> {
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

function send(ws: WebSocket, type: string, payload: unknown): void {
  ws.send(JSON.stringify({ type, payload }));
}

const sampleTrack = {
  trackId: 'spotify:track:4uLU6hMCjMI75M1A2tKUQC',
  title: 'Bohemian Rhapsody',
  artist: 'Queen',
  albumArt: 'https://example.com/album.jpg',
  durationMs: 354000,
};

describe('Music Listen-Along', () => {
  beforeEach(async () => {
    await startServer();
  });
  afterEach(async () => {
    await stopServer();
  });

  // ─── MUSIC_BROADCAST_START ───

  it('MUSIC_BROADCAST_START starts broadcast and broadcasts MUSIC_STATE', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    const bobReceives = collectMessages(wsB, 1);
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });

    // Alice receives MUSIC_STATE
    const aliceState = (await receiveJson(wsA)) as {
      type: string;
      payload: { broadcast: Record<string, unknown>; listeners: string[] };
    };
    expect(aliceState.type).toBe('MUSIC_STATE');
    expect(aliceState.payload.broadcast).not.toBeNull();
    expect(aliceState.payload.broadcast.broadcasterId).toBe(alice.participantId);
    expect(aliceState.payload.broadcast.platform).toBe('spotify');
    expect(aliceState.payload.broadcast.track).toMatchObject(sampleTrack);
    expect(aliceState.payload.listeners).toContain(alice.participantId);

    // Bob receives MUSIC_STATE
    const [bobState] = await bobReceives;
    expect((bobState as { type: string }).type).toBe('MUSIC_STATE');
    expect((bobState as { payload: { broadcast: { platform: string } } }).payload.broadcast.platform).toBe('spotify');

    wsA.close();
    wsB.close();
  });

  it('MUSIC_BROADCAST_START rejected if someone is already broadcasting', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob tries to start broadcasting - should fail
    send(wsB, 'MUSIC_BROADCAST_START', {
      platform: 'apple_music',
      track: sampleTrack,
      positionMs: 0,
      isPlaying: true,
    });

    const err = (await receiveJson(wsB)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('FORBIDDEN');
    expect(err.payload.message).toContain('already broadcasting');

    wsA.close();
    wsB.close();
  });

  // ─── MUSIC_SYNC ───

  it('MUSIC_SYNC broadcasts sync update to all participants', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Alice sends sync update
    const bobReceives = collectMessages(wsB, 1);
    send(wsA, 'MUSIC_SYNC', {
      track: sampleTrack,
      positionMs: 50000,
      isPlaying: true,
    });

    // Alice receives sync broadcast
    const aliceSync = (await receiveJson(wsA)) as {
      type: string;
      payload: { positionMs: number; isPlaying: boolean };
    };
    expect(aliceSync.type).toBe('MUSIC_SYNC_BROADCAST');
    expect(aliceSync.payload.positionMs).toBe(50000);

    // Bob receives sync broadcast
    const [bobSync] = await bobReceives;
    expect((bobSync as { type: string }).type).toBe('MUSIC_SYNC_BROADCAST');
    expect((bobSync as { payload: { positionMs: number } }).payload.positionMs).toBe(50000);

    wsA.close();
    wsB.close();
  });

  it('MUSIC_SYNC rejected if not the broadcaster', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob tries to send sync - should fail
    send(wsB, 'MUSIC_SYNC', {
      track: sampleTrack,
      positionMs: 99999,
      isPlaying: false,
    });

    const err = (await receiveJson(wsB)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('FORBIDDEN');
    expect(err.payload.message).toContain('broadcaster');

    wsA.close();
    wsB.close();
  });

  // ─── MUSIC_BROADCAST_STOP ───

  it('MUSIC_BROADCAST_STOP ends broadcast and clears listeners', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob joins as listener
    send(wsB, 'MUSIC_LISTENER_JOIN', {});
    await receiveJson(wsA); // MUSIC_STATE with Bob
    await receiveJson(wsB); // MUSIC_STATE with Bob

    // Alice stops broadcasting
    const bobReceives = collectMessages(wsB, 1);
    send(wsA, 'MUSIC_BROADCAST_STOP', {});

    // Alice receives MUSIC_STATE with null broadcast
    const aliceState = (await receiveJson(wsA)) as {
      type: string;
      payload: { broadcast: unknown; listeners: string[] };
    };
    expect(aliceState.type).toBe('MUSIC_STATE');
    expect(aliceState.payload.broadcast).toBeNull();
    expect(aliceState.payload.listeners).toHaveLength(0);

    // Bob receives the same
    const [bobState] = await bobReceives;
    expect((bobState as { type: string }).type).toBe('MUSIC_STATE');
    expect((bobState as { payload: { broadcast: unknown } }).payload.broadcast).toBeNull();

    wsA.close();
    wsB.close();
  });

  it('MUSIC_BROADCAST_STOP rejected if not the broadcaster', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob tries to stop - should fail
    send(wsB, 'MUSIC_BROADCAST_STOP', {});

    const err = (await receiveJson(wsB)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('FORBIDDEN');

    wsA.close();
    wsB.close();
  });

  // ─── MUSIC_LISTENER_JOIN ───

  it('MUSIC_LISTENER_JOIN adds listener and broadcasts MUSIC_STATE', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob joins as listener
    const aliceReceives = collectMessages(wsA, 1);
    send(wsB, 'MUSIC_LISTENER_JOIN', {});

    // Bob receives MUSIC_STATE with himself as listener
    const bobState = (await receiveJson(wsB)) as {
      type: string;
      payload: { listeners: string[] };
    };
    expect(bobState.type).toBe('MUSIC_STATE');
    expect(bobState.payload.listeners).toContain(bob.participantId);
    expect(bobState.payload.listeners).toContain(alice.participantId);

    // Alice receives it too
    const [aliceState] = await aliceReceives;
    expect((aliceState as { type: string }).type).toBe('MUSIC_STATE');

    wsA.close();
    wsB.close();
  });

  it('MUSIC_LISTENER_JOIN rejected if no active broadcast', async () => {
    const alice = await createAndJoin('Alice');
    const wsA = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);

    // Try to join with no broadcast
    send(wsA, 'MUSIC_LISTENER_JOIN', {});

    const err = (await receiveJson(wsA)) as {
      type: string;
      payload: { code: string; message: string };
    };
    expect(err.type).toBe('ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
    expect(err.payload.message).toContain('No active');

    wsA.close();
  });

  // ─── MUSIC_LISTENER_LEAVE ───

  it('MUSIC_LISTENER_LEAVE removes listener and broadcasts MUSIC_STATE', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob joins as listener
    send(wsB, 'MUSIC_LISTENER_JOIN', {});
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob leaves as listener
    const aliceReceives = collectMessages(wsA, 1);
    send(wsB, 'MUSIC_LISTENER_LEAVE', {});

    // Bob receives MUSIC_STATE without himself
    const bobState = (await receiveJson(wsB)) as {
      type: string;
      payload: { listeners: string[] };
    };
    expect(bobState.type).toBe('MUSIC_STATE');
    expect(bobState.payload.listeners).not.toContain(bob.participantId);
    expect(bobState.payload.listeners).toContain(alice.participantId);

    // Alice receives it too
    const [aliceState] = await aliceReceives;
    expect((aliceState as { type: string }).type).toBe('MUSIC_STATE');

    wsA.close();
    wsB.close();
  });

  // ─── Broadcaster leaving ends broadcast ───

  it('broadcaster disconnecting ends broadcast', async () => {
    const alice = await createAndJoin('Alice');
    const bob = await joinWithCode(alice.joinCode, 'Bob');

    const wsA = await connectWs();
    const wsB = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);
    const bobHelloMsgs = collectMessages(wsA, 1);
    await doHello(wsB, alice.sessionId, bob.participantId, bob.token);
    await bobHelloMsgs;

    // Alice starts broadcasting
    send(wsA, 'MUSIC_BROADCAST_START', {
      platform: 'spotify',
      track: sampleTrack,
      positionMs: 1000,
      isPlaying: true,
    });
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Bob joins as listener
    send(wsB, 'MUSIC_LISTENER_JOIN', {});
    await receiveJson(wsA); // MUSIC_STATE
    await receiveJson(wsB); // MUSIC_STATE

    // Alice disconnects - collect messages Bob receives
    const bobReceives = collectMessages(wsB, 2, 1000); // MUSIC_STATE + PARTICIPANT_LEFT
    wsA.close();

    const msgs = await bobReceives;
    // Should have MUSIC_STATE with null broadcast and PARTICIPANT_LEFT event
    const musicState = msgs.find((m) => (m as { type: string }).type === 'MUSIC_STATE') as {
      type: string;
      payload: { broadcast: unknown; listeners: string[] };
    };
    expect(musicState).toBeDefined();
    expect(musicState.payload.broadcast).toBeNull();
    expect(musicState.payload.listeners).toHaveLength(0);

    wsB.close();
  });

  // ─── Platform visible in MUSIC_STATE ───

  it('MUSIC_STATE includes platform so listeners know compatibility', async () => {
    const alice = await createAndJoin('Alice');
    const wsA = await connectWs();
    await doHello(wsA, alice.sessionId, alice.participantId, alice.token);

    // Try each platform
    for (const platform of ['spotify', 'apple_music', 'soundcloud'] as const) {
      send(wsA, 'MUSIC_BROADCAST_START', {
        platform,
        track: sampleTrack,
        positionMs: 0,
        isPlaying: true,
      });

      const state = (await receiveJson(wsA)) as {
        type: string;
        payload: { broadcast: { platform: string } };
      };
      expect(state.payload.broadcast.platform).toBe(platform);

      // Stop before next iteration
      send(wsA, 'MUSIC_BROADCAST_STOP', {});
      await receiveJson(wsA); // MUSIC_STATE with null
    }

    wsA.close();
  });
});
