import { describe, it, expect } from 'vitest';
import Fastify from 'fastify';
import { registerRoutes } from '../http/routes.js';

async function buildApp() {
  const app = Fastify({ logger: false });
  await registerRoutes(app);
  return app;
}

describe('HTTP Routes', () => {
  describe('GET /health', () => {
    it('returns status ok with metadata', async () => {
      const app = await buildApp();
      const res = await app.inject({ method: 'GET', url: '/health' });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.status).toBe('ok');
      expect(body).toHaveProperty('uptime');
      expect(body).toHaveProperty('sessions');
      expect(body).toHaveProperty('timestamp');
    });
  });

  describe('POST /sessions', () => {
    it('creates a session and returns ids', async () => {
      const app = await buildApp();
      const res = await app.inject({
        method: 'POST',
        url: '/sessions',
        payload: { displayName: 'Alice' },
      });
      expect(res.statusCode).toBe(201);
      const body = res.json();
      expect(body).toHaveProperty('sessionId');
      expect(body).toHaveProperty('joinCode');
      expect(body).toHaveProperty('participantId');
      expect(body).toHaveProperty('token');
      expect(body.joinCode).toHaveLength(6);
    });

    it('creates a session without displayName', async () => {
      const app = await buildApp();
      const res = await app.inject({
        method: 'POST',
        url: '/sessions',
        payload: {},
      });
      expect(res.statusCode).toBe(201);
      expect(res.json()).toHaveProperty('sessionId');
    });
  });

  describe('POST /sessions/join', () => {
    it('joins with valid code', async () => {
      const app = await buildApp();

      const createRes = await app.inject({
        method: 'POST',
        url: '/sessions',
        payload: { displayName: 'Alice' },
      });
      const { joinCode, sessionId } = createRes.json();

      const joinRes = await app.inject({
        method: 'POST',
        url: '/sessions/join',
        payload: { joinCode, displayName: 'Bob' },
      });
      expect(joinRes.statusCode).toBe(200);
      const body = joinRes.json();
      expect(body.sessionId).toBe(sessionId);
      expect(body).toHaveProperty('participantId');
      expect(body).toHaveProperty('token');
    });

    it('returns 404 for invalid code', async () => {
      const app = await buildApp();
      const res = await app.inject({
        method: 'POST',
        url: '/sessions/join',
        payload: { joinCode: 'ZZZZZZ' },
      });
      expect(res.statusCode).toBe(404);
    });

    it('returns 400 for missing joinCode', async () => {
      const app = await buildApp();
      const res = await app.inject({
        method: 'POST',
        url: '/sessions/join',
        payload: {},
      });
      expect(res.statusCode).toBe(400);
    });

    it('is case-insensitive for join codes', async () => {
      const app = await buildApp();
      const createRes = await app.inject({
        method: 'POST',
        url: '/sessions',
        payload: { displayName: 'Alice' },
      });
      const { joinCode } = createRes.json();

      const joinRes = await app.inject({
        method: 'POST',
        url: '/sessions/join',
        payload: { joinCode: joinCode.toLowerCase() },
      });
      expect(joinRes.statusCode).toBe(200);
    });
  });
});
