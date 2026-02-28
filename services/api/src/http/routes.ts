// HTTP route handlers: session create, join, health, session info.

import type { FastifyInstance } from 'fastify';
import { sessionStore } from '../state/session-store.js';
import { config } from '../config.js';

/** Sanitize and validate display name. Returns null if empty/invalid. */
function sanitizeDisplayName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  if (trimmed.length > config.maxDisplayNameLength) {
    return trimmed.slice(0, config.maxDisplayNameLength);
  }
  return trimmed;
}

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  // Health check — includes session stats for monitoring
  app.get('/health', async () => ({
    status: 'ok',
    uptime: process.uptime(),
    sessions: sessionStore.sessionCount,
    timestamp: Date.now(),
  }));

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
        lastSeenTs: p.lastSeenTs,
      });
    }

    return reply.status(200).send({
      sessionId: session.sessionId,
      joinCode: session.joinCode,
      hostParticipantId: session.hostParticipantId,
      destination: session.destination,
      participantCount: participants.length,
      participants,
      createdAt: session.createdAt,
    });
  });

  // Create a new session
  app.post<{
    Body: { displayName?: string };
  }>('/sessions', async (request, reply) => {
    const displayName = sanitizeDisplayName(request.body?.displayName);
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

    const cleanJoinCode = joinCode.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(cleanJoinCode)) {
      return reply.status(400).send({ error: 'joinCode must be 6 alphanumeric characters' });
    }

    // Check participant limit
    const session = sessionStore.getSessionByJoinCode(cleanJoinCode);
    if (session && session.participants.size >= config.maxParticipantsPerSession) {
      return reply.status(409).send({ error: 'Session is full' });
    }

    const result = sessionStore.joinSession(cleanJoinCode, sanitizeDisplayName(displayName) ?? null);
    if (!result) {
      return reply.status(404).send({ error: 'Invalid join code' });
    }

    return reply.status(200).send(result);
  });
}
