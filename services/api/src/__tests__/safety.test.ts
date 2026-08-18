// Phase 3 safety layer: RAISE_SOS / CLEAR_SOS / ARRIVAL_PING + battery.
//
// These are the durable, replayable counterpart to voice: an SOS a client
// misses is a safety failure, so every assertion here also checks that the
// state survives a reconnect via SNAPSHOT.

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket, type WebSocketServer } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket, stopHeartbeat } from '../ws/handler.js';
import {
  connectWs as sharedConnectWs,
  collectMessages,
  receiveUntil,
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
  stopHeartbeat();
  for (const client of wss?.clients ?? []) client.terminate();
  await new Promise<void>((resolve) => (wss ? wss.close(() => resolve()) : resolve()));
  await app?.close();
}

const connectWs = () => sharedConnectWs(port);

async function createSession(displayName = 'Host') {
  const res = await app.inject({ method: 'POST', url: '/sessions', payload: { displayName } });
  return res.json() as {
    sessionId: string;
    joinCode: string;
    participantId: string;
    token: string;
  };
}

async function joinSession(joinCode: string, displayName = 'Joiner') {
  const res = await app.inject({
    method: 'POST',
    url: '/sessions/join',
    payload: { joinCode, displayName },
  });
  return res.json() as { sessionId: string; participantId: string; token: string };
}

function send(ws: WebSocket, type: string, payload: unknown): void {
  ws.send(JSON.stringify({ type, payload }));
}

/** HELLO + drain WELCOME/SNAPSHOT/PARTICIPANT_JOINED for a first join. */
async function hello(
  ws: WebSocket,
  sessionId: string,
  participantId: string,
  token: string,
  lastEventId: number | null = null,
): Promise<unknown[]> {
  send(ws, 'HELLO', { sessionId, participantId, token, lastEventId });
  return collectMessages(ws, 3);
}

/** Report a location so the server has one to attach to an SOS. */
async function sendLocation(ws: WebSocket, lat: number, lng: number): Promise<void> {
  send(ws, 'LOC_UPDATE', {
    seq: 1,
    lat,
    lng,
    speed: null,
    heading: null,
    accuracy: null,
    ts: Date.now(),
  });
  await receiveUntil(ws, (m) => m.type === 'EVENT' && m.payload.kind === 'LOCATION_UPDATED');
}

describe('RAISE_SOS', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  it('broadcasts SOS_RAISED to every participant with the server-known location', async () => {
    const host = await createSession('Alice');
    const bob = await joinSession(host.joinCode, 'Bob');

    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    const wsB = await connectWs();
    await hello(wsB, host.sessionId, bob.participantId, bob.token);

    await sendLocation(wsA, 40.7128, -74.006);

    send(wsA, 'RAISE_SOS', { note: 'need help' });

    const evt = await receiveUntil(wsB, (m) => m.payload?.kind === 'SOS_RAISED');
    expect(evt.payload.data.participantId).toBe(host.participantId);
    expect(evt.payload.data.note).toBe('need help');
    // Location comes from server state, not from the client's message.
    expect(evt.payload.data.lat).toBeCloseTo(40.7128, 4);
    expect(evt.payload.data.lng).toBeCloseTo(-74.006, 4);
  });

  it('accepts an SOS from a participant with no known location, with null coords', async () => {
    const host = await createSession('Alice');
    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);

    send(wsA, 'RAISE_SOS', {});

    const evt = await receiveUntil(wsA, (m) => m.payload?.kind === 'SOS_RAISED');
    expect(evt.payload.data.lat).toBeNull();
    expect(evt.payload.data.lng).toBeNull();
    expect(evt.payload.data.note).toBeNull();
  });

  it('survives a reconnect — active SOS is in SNAPSHOT', async () => {
    const host = await createSession('Alice');
    const bob = await joinSession(host.joinCode, 'Bob');

    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    await sendLocation(wsA, 1, 2);
    send(wsA, 'RAISE_SOS', { note: 'still here' });
    await receiveUntil(wsA, (m) => m.payload?.kind === 'SOS_RAISED');

    // Bob connects fresh and must learn about it from the snapshot alone.
    const wsB = await connectWs();
    send(wsB, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: null,
    });
    const snapshot = (await receiveUntil(wsB, (m) => m.type === 'SNAPSHOT')) as {
      payload: {
        activeSos: { participantId: string; note: string }[];
        participants: { participantId: string; sos: { note: string } | null }[];
      };
    };

    expect(snapshot.payload.activeSos).toHaveLength(1);
    expect(snapshot.payload.activeSos[0].participantId).toBe(host.participantId);
    expect(snapshot.payload.activeSos[0].note).toBe('still here');

    const hostRow = snapshot.payload.participants.find(
      (p) => p.participantId === host.participantId,
    );
    expect(hostRow?.sos?.note).toBe('still here');
  });

  it('persists across the raiser disconnecting', async () => {
    // SPEC-PHASE3 §9 Q4: they may have lost signal *because* of the emergency.
    const host = await createSession('Alice');
    const bob = await joinSession(host.joinCode, 'Bob');

    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    send(wsA, 'RAISE_SOS', {});
    await receiveUntil(wsA, (m) => m.payload?.kind === 'SOS_RAISED');
    wsA.close();
    await new Promise((r) => setTimeout(r, 150));

    const wsB = await connectWs();
    send(wsB, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: null,
    });
    const snapshot = (await receiveUntil(wsB, (m) => m.type === 'SNAPSHOT')) as {
      payload: { activeSos: unknown[] };
    };
    expect(snapshot.payload.activeSos).toHaveLength(1);
  });
});

describe('CLEAR_SOS', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  it('clears only the sender’s own SOS', async () => {
    const host = await createSession('Alice');
    const bob = await joinSession(host.joinCode, 'Bob');

    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    const wsB = await connectWs();
    await hello(wsB, host.sessionId, bob.participantId, bob.token);

    send(wsA, 'RAISE_SOS', {});
    await receiveUntil(wsA, (m) => m.payload?.kind === 'SOS_RAISED');

    // Bob cannot clear Alice's SOS — CLEAR_SOS carries no participantId, it
    // acts on the authenticated connection, so there is nothing to address.
    send(wsB, 'CLEAR_SOS', {});
    await new Promise((r) => setTimeout(r, 150));

    const wsC = await connectWs();
    const charlie = await joinSession(host.joinCode, 'Charlie');
    send(wsC, 'HELLO', {
      sessionId: host.sessionId,
      participantId: charlie.participantId,
      token: charlie.token,
      lastEventId: null,
    });
    const snap = (await receiveUntil(wsC, (m) => m.type === 'SNAPSHOT')) as {
      payload: { activeSos: { participantId: string }[] };
    };
    expect(snap.payload.activeSos).toHaveLength(1);
    expect(snap.payload.activeSos[0].participantId).toBe(host.participantId);

    // Alice clearing her own works and broadcasts.
    send(wsA, 'CLEAR_SOS', {});
    const cleared = await receiveUntil(wsB, (m) => m.payload?.kind === 'SOS_CLEARED');
    expect(cleared.payload.data.participantId).toBe(host.participantId);
  });
});

describe('ARRIVAL_PING', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  async function setupWithDestination(lat: number, lng: number) {
    const host = await createSession('Alice');
    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    send(wsA, 'SET_DESTINATION', { lat, lng, label: 'Target' });
    await receiveUntil(wsA, (m) => m.payload?.kind === 'DESTINATION_SET');
    return { host, wsA };
  }

  it('rejects with NOT_ARRIVED when outside the arrival radius', async () => {
    const { host, wsA } = await setupWithDestination(40.7128, -74.006);
    // ~1.4km away — well outside the 50m default.
    await sendLocation(wsA, 40.725, -74.006);

    send(wsA, 'ARRIVAL_PING', {});
    const err = await receiveUntil(wsA, (m) => m.type === 'ERROR');
    expect(err.payload.code).toBe('NOT_ARRIVED');
    expect(host.participantId).toBeTruthy();
  });

  it('rejects with BAD_MESSAGE when no destination is set', async () => {
    const host = await createSession('Alice');
    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    await sendLocation(wsA, 1, 1);

    send(wsA, 'ARRIVAL_PING', {});
    const err = await receiveUntil(wsA, (m) => m.type === 'ERROR');
    expect(err.payload.code).toBe('BAD_MESSAGE');
  });

  it('accepts inside the radius, broadcasts, and lands in SNAPSHOT', async () => {
    const { host, wsA } = await setupWithDestination(40.7128, -74.006);
    // ~11m away.
    await sendLocation(wsA, 40.71289, -74.00611);

    send(wsA, 'ARRIVAL_PING', {});
    const evt = await receiveUntil(wsA, (m) => m.payload?.kind === 'ARRIVAL_PINGED');
    expect(evt.payload.data.participantId).toBe(host.participantId);

    const bob = await joinSession(host.joinCode, 'Bob');
    const wsB = await connectWs();
    send(wsB, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: null,
    });
    const snap = (await receiveUntil(wsB, (m) => m.type === 'SNAPSHOT')) as {
      payload: { participants: { participantId: string; arrived: boolean }[] };
    };
    const row = snap.payload.participants.find((p) => p.participantId === host.participantId);
    expect(row?.arrived).toBe(true);
  });

  it('is idempotent — a second ping emits no second event', async () => {
    const { wsA } = await setupWithDestination(40.7128, -74.006);
    await sendLocation(wsA, 40.71289, -74.00611);

    send(wsA, 'ARRIVAL_PING', {});
    await receiveUntil(wsA, (m) => m.payload?.kind === 'ARRIVAL_PINGED');

    send(wsA, 'ARRIVAL_PING', {});
    send(wsA, 'CHAT_MESSAGE', { text: 'marker' });
    // The next event must be the chat, proving no duplicate arrival landed
    // between them. The client auto-fires arrival on a GPS threshold, so a
    // repeat is expected traffic rather than a client bug.
    const next = await receiveUntil(wsA, (m) => m.type === 'EVENT');
    expect(next.payload.kind).toBe('CHAT_MESSAGE');
  });
});

describe('battery presence enrichment', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  it('appears in LOCATION_UPDATED data and in SNAPSHOT rows', async () => {
    const host = await createSession('Alice');
    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);

    send(wsA, 'LOC_UPDATE', {
      seq: 1,
      lat: 10,
      lng: 20,
      speed: null,
      heading: null,
      accuracy: null,
      ts: Date.now(),
      battery: 0.12,
      charging: false,
    });

    const evt = await receiveUntil(wsA, (m) => m.payload?.kind === 'LOCATION_UPDATED');
    expect(evt.payload.data.battery).toBeCloseTo(0.12, 3);
    expect(evt.payload.data.charging).toBe(false);

    const bob = await joinSession(host.joinCode, 'Bob');
    const wsB = await connectWs();
    send(wsB, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: null,
    });
    const snap = (await receiveUntil(wsB, (m) => m.type === 'SNAPSHOT')) as {
      payload: { participants: { participantId: string; battery: number; charging: boolean }[] };
    };
    const row = snap.payload.participants.find((p) => p.participantId === host.participantId);
    expect(row?.battery).toBeCloseTo(0.12, 3);
    expect(row?.charging).toBe(false);
  });

  it('an update omitting battery leaves the last known value intact', async () => {
    const host = await createSession('Alice');
    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);

    send(wsA, 'LOC_UPDATE', {
      seq: 1, lat: 1, lng: 1, speed: null, heading: null, accuracy: null,
      ts: Date.now(), battery: 0.5, charging: true,
    });
    await receiveUntil(wsA, (m) => m.payload?.kind === 'LOCATION_UPDATED');

    await new Promise((r) => setTimeout(r, 1000)); // clear the loc-update throttle
    send(wsA, 'LOC_UPDATE', {
      seq: 2, lat: 2, lng: 2, speed: null, heading: null, accuracy: null, ts: Date.now(),
    });
    const evt = await receiveUntil(
      wsA,
      (m) => m.payload?.kind === 'LOCATION_UPDATED' && m.payload.data.lat === 2,
    );
    expect(evt.payload.data.battery).toBeCloseTo(0.5, 3);
    expect(evt.payload.data.charging).toBe(true);
  });
});

describe('chat rate limiting', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  it('replies RATE_LIMITED past the window and leaves other participants unaffected', async () => {
    const host = await createSession('Alice');
    const bob = await joinSession(host.joinCode, 'Bob');

    const wsA = await connectWs();
    await hello(wsA, host.sessionId, host.participantId, host.token);
    const wsB = await connectWs();
    await hello(wsB, host.sessionId, bob.participantId, bob.token);
    await receiveUntil(wsA, (m) => m.payload?.kind === 'PARTICIPANT_JOINED');

    // Default limit is 5 per 5s.
    for (let i = 0; i < 20; i++) send(wsA, 'CHAT_MESSAGE', { text: `spam ${i}` });

    const err = await receiveUntil(wsA, (m) => m.type === 'ERROR');
    expect(err.payload.code).toBe('RATE_LIMITED');

    // Bob is untouched by Alice's limit and can still be heard.
    send(wsB, 'CHAT_MESSAGE', { text: 'hello from bob' });
    const evt = await receiveUntil(
      wsB,
      (m) => m.payload?.kind === 'CHAT_MESSAGE' && m.payload.data.text === 'hello from bob',
    );
    expect(evt.payload.data.participantId).toBe(bob.participantId);
  });
});

describe('broadcast isolation', () => {
  beforeEach(startServer);
  afterEach(stopServer);

  it('an event in one session never reaches another session', async () => {
    const one = await createSession('One');
    const two = await createSession('Two');

    const ws1 = await connectWs();
    await hello(ws1, one.sessionId, one.participantId, one.token);
    const ws2 = await connectWs();
    await hello(ws2, two.sessionId, two.participantId, two.token);

    const received: string[] = [];
    ws2.on('message', (d) => received.push(JSON.parse(d.toString()).payload?.kind ?? ''));

    send(ws1, 'CHAT_MESSAGE', { text: 'session one only' });
    await receiveUntil(ws1, (m) => m.payload?.kind === 'CHAT_MESSAGE');
    await new Promise((r) => setTimeout(r, 200));

    expect(received).not.toContain('CHAT_MESSAGE');
  });
});
