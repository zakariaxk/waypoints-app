// End-to-end smoke test over a real server and real sockets.
//
// One test exercising the whole session lifecycle, written because the bug it
// covers — replayed events being silently discarded after a reconnect — was
// invisible to every existing unit test. The server was correct; the client
// threw the replay away. Only a test that disconnects, generates events, and
// reconnects can see that.

import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { type WebSocketServer } from 'ws';
import { registerRoutes } from '../http/routes.js';
import { setupWebSocket, stopHeartbeat } from '../ws/handler.js';
import {
  connectWs as sharedConnectWs,
  receiveUntil,
  collectMessages,
} from './helpers/ws-test-client.js';

let app: FastifyInstance;
let port: number;
let wss: WebSocketServer | undefined;

beforeAll(async () => {
  app = Fastify({ logger: false });
  await registerRoutes(app);
  await app.listen({ port: 0, host: '127.0.0.1' });
  wss = setupWebSocket(app.server);
  const addr = app.server.address();
  port = typeof addr === 'object' && addr ? addr.port : 0;
});

afterAll(async () => {
  stopHeartbeat();
  for (const client of wss?.clients ?? []) client.terminate();
  await new Promise<void>((resolve) => (wss ? wss.close(() => resolve()) : resolve()));
  await app?.close();
});

function send(ws: { send: (data: string) => void }, type: string, payload: unknown): void {
  ws.send(JSON.stringify({ type, payload }));
}

describe('full session lifecycle', () => {
  it('survives a disconnect with no lost events and no lost safety state', async () => {
    // ── create + join ────────────────────────────────────────────────────
    const host = (await app
      .inject({ method: 'POST', url: '/sessions', payload: { displayName: 'Alice' } })
      .then((r) => r.json())) as {
      sessionId: string;
      joinCode: string;
      participantId: string;
      token: string;
    };
    const bob = (await app
      .inject({
        method: 'POST',
        url: '/sessions/join',
        payload: { joinCode: host.joinCode, displayName: 'Bob' },
      })
      .then((r) => r.json())) as { participantId: string; token: string };

    const wsA = await sharedConnectWs(port);
    const wsB = await sharedConnectWs(port);

    send(wsA, 'HELLO', {
      sessionId: host.sessionId,
      participantId: host.participantId,
      token: host.token,
      lastEventId: null,
    });
    await collectMessages(wsA, 3);

    send(wsB, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: null,
    });
    await collectMessages(wsB, 3);

    // ── location carries battery through to the other participant ────────
    send(wsA, 'LOC_UPDATE', {
      seq: 1,
      lat: 40.7128,
      lng: -74.006,
      speed: 1,
      heading: 0,
      accuracy: 5,
      ts: Date.now(),
      battery: 0.09,
      charging: false,
    });
    const loc = await receiveUntil(wsB, (m) => m.payload?.kind === 'LOCATION_UPDATED');
    expect(loc.payload.data.battery).toBeCloseTo(0.09, 3);
    expect(loc.payload.data.charging).toBe(false);

    // ── SOS, with coordinates taken from server state ────────────────────
    send(wsA, 'RAISE_SOS', { note: 'stuck on 5th' });
    const sos = await receiveUntil(wsB, (m) => m.payload?.kind === 'SOS_RAISED');
    expect(sos.payload.data.note).toBe('stuck on 5th');
    expect(sos.payload.data.lat).toBeCloseTo(40.7128, 4);

    const lastEventIdForBob = sos.payload.eventId;

    // ── Bob drops; three chats happen while he is gone ───────────────────
    wsB.close();
    await new Promise((r) => setTimeout(r, 200));

    for (const text of ['one', 'two', 'three']) {
      send(wsA, 'CHAT_MESSAGE', { text });
    }
    await new Promise((r) => setTimeout(r, 200));

    // ── Bob reconnects and must receive all three, exactly once ──────────
    const wsB2 = await sharedConnectWs(port);
    send(wsB2, 'HELLO', {
      sessionId: host.sessionId,
      participantId: bob.participantId,
      token: bob.token,
      lastEventId: lastEventIdForBob,
    });

    const snapshot = await receiveUntil(wsB2, (m) => m.type === 'SNAPSHOT');
    const events = await receiveUntil(wsB2, (m) => m.type === 'EVENTS');

    const chats = (events.payload.events as { kind: string; data: { text?: string } }[])
      .filter((e) => e.kind === 'CHAT_MESSAGE')
      .map((e) => e.data.text);
    expect(chats).toEqual(['one', 'two', 'three']);

    // Safety state is durable across the reconnect, unlike voice.
    expect(snapshot.payload.activeSos).toHaveLength(1);
    expect(snapshot.payload.activeSos[0].participantId).toBe(host.participantId);

    // Battery rides presence, so it is on the snapshot row too.
    const hostRow = (snapshot.payload.participants as { participantId: string; battery: number }[])
      .find((p) => p.participantId === host.participantId);
    expect(hostRow?.battery).toBeCloseTo(0.09, 3);

    // A reconnect is not a join.
    await new Promise((r) => setTimeout(r, 150));
    const sawJoin = await receiveUntil(wsB2, () => true, 300)
      .then((m) => m.payload?.kind === 'PARTICIPANT_JOINED')
      .catch(() => false);
    expect(sawJoin).toBe(false);

    wsA.close();
    wsB2.close();
  });
});
