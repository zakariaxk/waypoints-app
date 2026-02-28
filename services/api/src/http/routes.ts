// HTTP route handlers: session create, join, health.

import type { FastifyInstance } from 'fastify';
import { sessionStore } from '../state/session-store.js';

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  // Health check
  app.get('/health', async () => ({ status: 'ok' }));

  // Session info
  app.get<{
    Params: { sessionId: string };
  }>('/sessions/:sessionId', async (request, reply) => {
    const { sessionId } = request.params;
    const session = sessionStore.getSession(sessionId);
    if (!session) {
      return reply.status(404).send({ error: 'Session not found' });
    }

    const participants = [];
    for (const p of session.participants.values()) {
      participants.push({
        participantId: p.participantId,
        displayName: p.displayName,
        status: p.status,
      });
    }

    return reply.status(200).send({
      sessionId: session.sessionId,
      joinCode: session.joinCode,
      hostParticipantId: session.hostParticipantId,
      destination: session.destination,
      participantCount: participants.length,
      participants,
    });
  });

  // Create a new session
  app.post<{
    Body: { displayName?: string };
  }>('/sessions', async (request, reply) => {
    const displayName = request.body?.displayName ?? null;
    const result = sessionStore.createSession(displayName);
    return reply.status(201).send(result);
  });

  // Join an existing session
  app.post<{
    Body: { joinCode: string; displayName?: string };
  }>('/sessions/join', async (request, reply) => {
    const { joinCode, displayName } = request.body ?? {};

    if (!joinCode || typeof joinCode !== 'string') {
      return reply.status(400).send({ error: 'joinCode is required' });
    }

    const result = sessionStore.joinSession(joinCode, displayName ?? null);
    if (!result) {
      return reply.status(404).send({ error: 'Invalid join code' });
    }

    return reply.status(200).send(result);
  });
}
