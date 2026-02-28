// WebSocket message types matching docs/WS-PROTOCOL.md exactly.
// Discriminated unions keyed on "type".

import type { Destination, Location, ParticipantSnapshot } from './types.js';

// ─── Client → Server ───

export interface HelloMessage {
  type: 'HELLO';
  payload: {
    sessionId: string;
    participantId: string;
    token: string;
    lastEventId: number | null;
  };
}

export interface LocUpdateMessage {
  type: 'LOC_UPDATE';
  payload: {
    seq: number;
    lat: number;
    lng: number;
    speed: number | null;
    heading: number | null;
    accuracy: number | null;
    ts: number;
  };
}

export interface SetDestinationMessage {
  type: 'SET_DESTINATION';
  payload: {
    lat: number;
    lng: number;
    label: string | null;
  };
}

export type ClientMessage = HelloMessage | LocUpdateMessage | SetDestinationMessage;

// ─── Server → Client ───

export interface WelcomeMessage {
  type: 'WELCOME';
  payload: {
    connId: string;
    sessionId: string;
    participantId: string;
    latestEventId: number;
  };
}

export interface SnapshotMessage {
  type: 'SNAPSHOT';
  payload: {
    latestEventId: number;
    destination: Destination | null;
    participants: ParticipantSnapshot[];
  };
}

export interface EventsMessage {
  type: 'EVENTS';
  payload: {
    fromEventId: number;
    toEventId: number;
    events: SessionEvent[];
  };
}

export interface ErrorMessage {
  type: 'ERROR';
  payload: {
    code: ErrorCode;
    message: string;
  };
}

export type ServerMessage = WelcomeMessage | SnapshotMessage | EventsMessage | ErrorMessage;

// ─── Event types (broadcast) ───

export type EventKind =
  | 'PARTICIPANT_JOINED'
  | 'PARTICIPANT_LEFT'
  | 'LOCATION_UPDATED'
  | 'DESTINATION_SET';

export interface BaseEvent {
  eventId: number;
  ts: number; // server epoch ms
  kind: EventKind;
}

export interface ParticipantJoinedEvent extends BaseEvent {
  kind: 'PARTICIPANT_JOINED';
  data: { participantId: string };
}

export interface ParticipantLeftEvent extends BaseEvent {
  kind: 'PARTICIPANT_LEFT';
  data: { participantId: string };
}

export interface LocationUpdatedEvent extends BaseEvent {
  kind: 'LOCATION_UPDATED';
  data: {
    participantId: string;
    lat: number;
    lng: number;
    speed: number | null;
    heading: number | null;
    accuracy: number | null;
    ts: number;
  };
}

export interface DestinationSetEvent extends BaseEvent {
  kind: 'DESTINATION_SET';
  data: {
    lat: number;
    lng: number;
    label: string | null;
  };
}

export type SessionEvent =
  | ParticipantJoinedEvent
  | ParticipantLeftEvent
  | LocationUpdatedEvent
  | DestinationSetEvent;

// ─── Error codes ───

export type ErrorCode = 'BAD_MESSAGE' | 'UNAUTHORIZED' | 'NOT_IN_SESSION' | 'RATE_LIMITED';
