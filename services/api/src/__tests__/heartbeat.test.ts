// WS heartbeat: half-open connections must be reaped.
//
// The config singleton is evaluated at import time, so this file sets a short
// heartbeat interval into the environment and imports the modules dynamically.
// A real interval (15s) would make the test unbearably slow.

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import Fastify, { type FastifyInstance } from 'fastify';
import { WebSocket, type WebSocketServer } from 'ws';

const HEARTBEAT_MS = 150;

let app: FastifyInstance;
let port: number;
let wss: WebSocketServer | undefined;
let stopHeartbeat: () => void;
let sessionStore: typeof import('../state/session-store.js')['sessionStore'];

beforeEach(async () => {
  process.env.WS_HEARTBEAT_INTERVAL_MS = String(HEARTBEAT_MS);
  const { resetModules } = await import('vitest').then((m) => ({ resetModules: m.vi.resetModules }));
  resetModules();

  const routes = await import('../http/routes.js');
  const handler = await import('../ws/handler.js');
  const store = await import('../state/session-store.js');
  stopHeartbeat = handler.stopHeartbeat;
  sessionStore = store.sessionStore;

  app = Fastify({ logger: false });
  await routes.registerRoutes(app);
  await app.listen({ port: 0, host: '127.0.0.1' });
  wss = handler.setupWebSocket(app.server);
  const addr = app.server.address();
  port = typeof addr === 'object' && addr ? addr.port : 0;
});

afterEach(async () => {
  stopHeartbeat();
  for (const client of wss?.clients ?? []) client.terminate();
  await new Promise<void>((resolve) => (wss ? wss.close(() => resolve()) : resolve()));
  await app?.close();
  delete process.env.WS_HEARTBEAT_INTERVAL_MS;
});

describe('WS heartbeat', () => {
  it('terminates a connection that stops answering pings and marks the participant offline', async () => {
    const created = (await app
      .inject({ method: 'POST', url: '/sessions', payload: { displayName: 'Ghost' } })
      .then((r) => r.json())) as { sessionId: string; participantId: string; token: string };

    // autoPong: false makes this client behave like a device whose network
    // vanished — the socket looks open locally but nothing comes back.
    const ws = new WebSocket(`ws://127.0.0.1:${port}`, { autoPong: false });
    await new Promise<void>((resolve) => ws.on('open', () => resolve()));

    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: {
          sessionId: created.sessionId,
          participantId: created.participantId,
          token: created.token,
          lastEventId: null,
        },
      }),
    );
    await new Promise((r) => setTimeout(r, 100));

    const participant = sessionStore.getParticipant(created.sessionId, created.participantId);
    expect(participant?.status).toBe('online');
    expect(participant?.connId).not.toBeNull();

    // Two sweeps: the first pings, the second finds no pong and terminates.
    await new Promise((r) => setTimeout(r, HEARTBEAT_MS * 4));

    expect(participant?.status).toBe('offline');
    expect(participant?.connId).toBeNull();
  });

  it('keeps a healthy connection alive across several sweeps', async () => {
    const created = (await app
      .inject({ method: 'POST', url: '/sessions', payload: { displayName: 'Healthy' } })
      .then((r) => r.json())) as { sessionId: string; participantId: string; token: string };

    const ws = new WebSocket(`ws://127.0.0.1:${port}`); // autoPong on by default
    await new Promise<void>((resolve) => ws.on('open', () => resolve()));
    ws.send(
      JSON.stringify({
        type: 'HELLO',
        payload: {
          sessionId: created.sessionId,
          participantId: created.participantId,
          token: created.token,
          lastEventId: null,
        },
      }),
    );
    await new Promise((r) => setTimeout(r, HEARTBEAT_MS * 5));

    const participant = sessionStore.getParticipant(created.sessionId, created.participantId);
    expect(participant?.status).toBe('online');
    expect(ws.readyState).toBe(WebSocket.OPEN);
    ws.close();
  });
});
