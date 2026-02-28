import { describe, it, expect } from 'vitest';
import { updatePresenceForSession } from '../state/presence.js';
import type { FullSessionState, FullParticipantState } from '../state/session-store.js';
import { EventBuffer } from '../state/event-buffer.js';

function makeParticipant(overrides: Partial<FullParticipantState> = {}): FullParticipantState {
  return {
    participantId: 'p1',
    displayName: null,
    token: 'tok',
    lastLocation: null,
    status: 'online',
    lastSeenTs: Date.now(),
    connId: 'conn1',
    lastLocUpdateTs: 0,
    ...overrides,
  };
}

function makeSession(participants: FullParticipantState[]): FullSessionState {
  const map = new Map<string, FullParticipantState>();
  for (const p of participants) {
    map.set(p.participantId, p);
  }
  return {
    sessionId: 's1',
    joinCode: 'ABC123',
    hostParticipantId: participants[0]?.participantId ?? 'p1',
    destination: null,
    lastEventId: 0,
    createdAt: Date.now(),
    participants: map,
    eventBuffer: new EventBuffer(100),
  };
}

describe('Presence', () => {
  it('marks participant as online when recently seen with connection', () => {
    const p = makeParticipant({ lastSeenTs: Date.now(), connId: 'c1' });
    const session = makeSession([p]);
    updatePresenceForSession(session);
    expect(p.status).toBe('online');
  });

  it('marks participant as stale after threshold', () => {
    const p = makeParticipant({
      lastSeenTs: Date.now() - 15_000, // 15s ago (stale threshold = 10s)
      connId: 'c1',
    });
    const session = makeSession([p]);
    updatePresenceForSession(session);
    expect(p.status).toBe('stale');
  });

  it('marks participant as offline after offline threshold', () => {
    const p = makeParticipant({
      lastSeenTs: Date.now() - 35_000, // 35s ago (offline threshold = 30s)
      connId: 'c1',
    });
    const session = makeSession([p]);
    updatePresenceForSession(session);
    expect(p.status).toBe('offline');
  });

  it('marks participant as offline when no connId', () => {
    const p = makeParticipant({ connId: null, lastSeenTs: Date.now() });
    const session = makeSession([p]);
    updatePresenceForSession(session);
    expect(p.status).toBe('offline');
  });
});
