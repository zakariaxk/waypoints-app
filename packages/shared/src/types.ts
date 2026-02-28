// Domain types matching docs/ARCHITECTURE.md

export type PresenceStatus = 'online' | 'stale' | 'offline';

export interface Location {
  lat: number;
  lng: number;
  speed: number | null;
  heading: number | null;
  accuracy: number | null;
  ts: number; // client epoch ms
}

export interface Destination {
  lat: number;
  lng: number;
  label: string | null;
}

export interface ParticipantSnapshot {
  participantId: string;
  displayName: string | null;
  lastLocation: Location | null;
  lastSeenTs: number;
  status: PresenceStatus;
}

export interface SessionSnapshot {
  latestEventId: number;
  destination: Destination | null;
  participants: ParticipantSnapshot[];
}

// Server-side state (not sent over the wire as-is)
export interface ParticipantState {
  participantId: string;
  displayName: string | null;
  token: string;
  lastLocation: Location | null;
  status: PresenceStatus;
  lastSeenTs: number;
  connId: string | null;
}

export interface SessionState {
  sessionId: string;
  joinCode: string;
  hostParticipantId: string;
  destination: Destination | null;
  lastEventId: number;
  createdAt: number;
}
