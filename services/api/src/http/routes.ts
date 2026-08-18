// HTTP route handlers: session create, join, health, session info.

import type { FastifyInstance, FastifyRequest } from 'fastify';
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

/**
 * Fixed-window per-IP counter for join attempts.
 *
 * Join codes are 6 characters from a 32-symbol alphabet (~10^9 keyspace), so
 * guessing is not cheap — but without a limit it is *free*, and an attacker
 * who lands one gets the live location of everyone in that session. Swept by
 * the same cleanup timer as sessions so the map cannot grow without bound.
 */
const joinAttempts = new Map<string, { count: number; windowStart: number }>();

function isJoinRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = joinAttempts.get(ip);
  if (!entry || now - entry.windowStart >= config.joinRateLimitWindowMs) {
    joinAttempts.set(ip, { count: 1, windowStart: now });
    return false;
  }
  entry.count += 1;
  return entry.count > config.joinRateLimitCount;
}

/** Drop expired join-rate-limit windows. Called by the cleanup sweep. */
export function sweepJoinRateLimits(): void {
  const now = Date.now();
  for (const [ip, entry] of joinAttempts) {
    if (now - entry.windowStart >= config.joinRateLimitWindowMs) {
      joinAttempts.delete(ip);
    }
  }
}

/** Participant token from `Authorization: Bearer <token>` or `?token=`. */
function readToken(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  if (typeof header === 'string' && header.startsWith('Bearer ')) {
    return header.slice(7).trim() || null;
  }
  const query = request.query as { token?: unknown } | undefined;
  if (query && typeof query.token === 'string' && query.token.trim()) {
    return query.token.trim();
  }
  return null;
}

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  // Health check — includes session stats for monitoring
  app.get('/health', async () => ({
    status: 'ok',
    uptime: process.uptime(),
    sessions: sessionStore.sessionCount,
    timestamp: Date.now(),
  }));

  // Session info.
  //
  // Requires a participant token for that session. This returns every
  // participant's display name and presence, which for a location-sharing app
  // is exactly the sort of thing that should not be readable by anyone who
  // learns a session id. The token model matches the WS HELLO handshake — no
  // new auth concept. Responds 404 rather than 401/403 so the endpoint does
  // not confirm that an id exists to a caller who cannot read it.
  app.get<{
    Params: { sessionId: string };
  }>('/sessions/:sessionId', async (request, reply) => {
    const { sessionId } = request.params;
    const session = sessionStore.getSession(sessionId);
    if (!session) {
      return reply.status(404).send({ error: 'Session not found' });
    }

    const token = readToken(request);
    const authorized =
      token !== null && [...session.participants.values()].some((p) => p.token === token);
    if (!authorized) {
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

  // Lightweight unauthenticated existence probe for the join screen. Reveals
  // only whether a code is live and how full it is — no names, no locations.
  app.get<{
    Params: { joinCode: string };
  }>('/sessions/by-code/:joinCode/exists', async (request, reply) => {
    const joinCode = request.params.joinCode.trim().toUpperCase();
    if (!/^[A-Z0-9]{6}$/.test(joinCode)) {
      return reply.status(400).send({ error: 'joinCode must be 6 alphanumeric characters' });
    }
    if (isJoinRateLimited(request.ip)) {
      return reply.status(429).send({ error: 'Too many attempts — slow down' });
    }
    const session = sessionStore.getSessionByJoinCode(joinCode);
    if (!session) {
      return reply.status(404).send({ exists: false });
    }
    return reply.status(200).send({
      exists: true,
      participantCount: session.participants.size,
      isFull: session.participants.size >= config.maxParticipantsPerSession,
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

    // Rate limit applies only to well-formed codes, so a client fat-fingering
    // the format is not penalised, but a guesser is.
    if (isJoinRateLimited(request.ip)) {
      return reply.status(429).send({ error: 'Too many join attempts — try again shortly' });
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
