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

// Active SOS as surfaced in a snapshot. lat/lng may be null when the sender
// had no known location yet (Phase 3 spec §9 Q2).
export interface ActiveSos {
  participantId: string;
  note: string | null;
  lat: number | null;
  lng: number | null;
  ts: number;
}

export interface ParticipantSnapshot {
  participantId: string;
  displayName: string | null;
  lastLocation: Location | null;
  lastSeenTs: number;
  status: PresenceStatus;
  battery: number | null; // 0..1, latest reported
  charging: boolean | null;
  arrived: boolean;
  sos: { note: string | null; ts: number } | null;
}

export interface SessionSnapshot {
  latestEventId: number;
  destination: Destination | null;
  participants: ParticipantSnapshot[];
  activeSos: ActiveSos[];
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
  battery: number | null; // 0..1, latest reported
  charging: boolean | null;
}

export interface SessionState {
  sessionId: string;
  joinCode: string;
  hostParticipantId: string;
  destination: Destination | null;
  lastEventId: number;
  createdAt: number;
  sosActive: Map<string, { note: string | null; ts: number }>; // participantId → SOS; durable in snapshot
  arrived: Set<string>; // participantIds who pinged arrival; durable in snapshot
}
