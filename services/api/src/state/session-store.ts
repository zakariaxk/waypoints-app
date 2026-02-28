// In-memory session store. Single source of truth for all session state.

import { v4 as uuid } from 'uuid';
import type {
  ParticipantState,
  SessionState,
  Destination,
  Location,
  SessionEvent,
  ParticipantSnapshot,
  SessionSnapshot,
} from '@waypoints/shared';
import { EventBuffer } from './event-buffer.js';
import { updatePresenceForSession } from './presence.js';
import { config } from '../config.js';

export interface FullSessionState extends SessionState {
  participants: Map<string, FullParticipantState>;
  eventBuffer: EventBuffer;
}

export interface FullParticipantState extends ParticipantState {
  /** Timestamp of last LOC_UPDATE accepted (for rate limiting) */
  lastLocUpdateTs: number;
}

class SessionStore {
  private sessions = new Map<string, FullSessionState>();
  private joinCodeIndex = new Map<string, string>(); // joinCode → sessionId

  /** Generate a 6-char alphanumeric join code. */
  private generateJoinCode(): string {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no 0/O/1/I ambiguity
    let code = '';
    for (let i = 0; i < 6; i++) {
      code += chars[Math.floor(Math.random() * chars.length)];
    }
    // Ensure uniqueness
    if (this.joinCodeIndex.has(code)) return this.generateJoinCode();
    return code;
  }

  createSession(hostDisplayName: string | null): {
    sessionId: string;
    joinCode: string;
    participantId: string;
    token: string;
  } {
    const sessionId = uuid();
    const joinCode = this.generateJoinCode();
    const participantId = uuid();
    const token = uuid();

    const session: FullSessionState = {
      sessionId,
      joinCode,
      hostParticipantId: participantId,
      destination: null,
      lastEventId: 0,
      createdAt: Date.now(),
      participants: new Map(),
      eventBuffer: new EventBuffer(config.eventBufferCapacity),
    };

    const participant: FullParticipantState = {
      participantId,
      displayName: hostDisplayName,
      token,
      lastLocation: null,
      status: 'offline', // becomes online on WS connect
      lastSeenTs: Date.now(),
      connId: null,
      lastLocUpdateTs: 0,
    };

    session.participants.set(participantId, participant);
    this.sessions.set(sessionId, session);
    this.joinCodeIndex.set(joinCode, sessionId);

    return { sessionId, joinCode, participantId, token };
  }

  joinSession(
    joinCode: string,
    displayName: string | null,
  ): { sessionId: string; participantId: string; token: string } | null {
    const sessionId = this.joinCodeIndex.get(joinCode.toUpperCase());
    if (!sessionId) return null;

    const session = this.sessions.get(sessionId);
    if (!session) return null;

    const participantId = uuid();
    const token = uuid();

    const participant: FullParticipantState = {
      participantId,
      displayName,
      token,
      lastLocation: null,
      status: 'offline',
      lastSeenTs: Date.now(),
      connId: null,
      lastLocUpdateTs: 0,
    };

    session.participants.set(participantId, participant);
    return { sessionId, participantId, token };
  }

  getSession(sessionId: string): FullSessionState | undefined {
    return this.sessions.get(sessionId);
  }

  getParticipant(sessionId: string, participantId: string): FullParticipantState | undefined {
    return this.sessions.get(sessionId)?.participants.get(participantId);
  }

  /** Assign next eventId, push event to buffer, return the event. */
  pushEvent(
    sessionId: string,
    kind: SessionEvent['kind'],
    data: SessionEvent['data'],
  ): SessionEvent | null {
    const session = this.sessions.get(sessionId);
    if (!session) return null;

    session.lastEventId += 1;
    const event = {
      eventId: session.lastEventId,
      ts: Date.now(),
      kind,
      data,
    } as SessionEvent;

    session.eventBuffer.push(event);
    return event;
  }

  /** Build a snapshot for the SNAPSHOT message. */
  buildSnapshot(sessionId: string): SessionSnapshot | null {
    const session = this.sessions.get(sessionId);
    if (!session) return null;

    const participants: ParticipantSnapshot[] = [];
    for (const p of session.participants.values()) {
      participants.push({
        participantId: p.participantId,
        displayName: p.displayName,
        lastLocation: p.lastLocation,
        lastSeenTs: p.lastSeenTs,
        status: p.status,
      });
    }

    return {
      latestEventId: session.lastEventId,
      destination: session.destination,
      participants,
    };
  }

  /** Get missed events for reconnect replay. Returns null if gap is too large. */
  getMissedEvents(sessionId: string, lastEventId: number): SessionEvent[] | null {
    const session = this.sessions.get(sessionId);
    if (!session) return null;

    if (lastEventId >= session.lastEventId) return []; // nothing missed

    const oldest = session.eventBuffer.oldestEventId();
    if (oldest === 0 || lastEventId < oldest - 1) {
      // Gap too large — caller should use snapshot only
      return null;
    }

    return session.eventBuffer.getRange(lastEventId, session.lastEventId);
  }

  /** Remove stale/empty sessions. Called periodically. */
  cleanup(): number {
    const now = Date.now();
    let removed = 0;
    for (const [sessionId, session] of this.sessions) {
      const isEmpty = session.participants.size === 0;
      const isExpired = now - session.createdAt > config.sessionTtlMs;
      if (isEmpty || isExpired) {
        this.joinCodeIndex.delete(session.joinCode);
        this.sessions.delete(sessionId);
        removed++;
      }
    }
    return removed;
  }

  /** Total sessions (for diagnostics). */
  get sessionCount(): number {
    return this.sessions.size;
  }

  /** Run presence sweep across all sessions. */
  sweepPresence(): void {
    for (const session of this.sessions.values()) {
      updatePresenceForSession(session);
    }
  }

  /** Get session by join code. */
  getSessionByJoinCode(joinCode: string): FullSessionState | undefined {
    const sessionId = this.joinCodeIndex.get(joinCode.toUpperCase());
    if (!sessionId) return undefined;
    return this.sessions.get(sessionId);
  }

  /** Remove a participant from a session entirely. */
  removeParticipant(sessionId: string, participantId: string): boolean {
    const session = this.sessions.get(sessionId);
    if (!session) return false;
    return session.participants.delete(participantId);
  }
}

// Singleton
export const sessionStore = new SessionStore();
