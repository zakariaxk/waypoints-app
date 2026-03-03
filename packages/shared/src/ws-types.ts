// WebSocket message types matching docs/WS-PROTOCOL.md exactly.
// Discriminated unions keyed on "type".

import type { Destination, Location, ParticipantSnapshot, MusicPlatform, MusicTrack, MusicBroadcast } from './types.js';

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

export interface ChatMessageMessage {
  type: 'CHAT_MESSAGE';
  payload: {
    text: string;
  };
}

export interface LeaveSessionMessage {
  type: 'LEAVE_SESSION';
  payload: Record<string, never>;
}

export interface ClearDestinationMessage {
  type: 'CLEAR_DESTINATION';
  payload: Record<string, never>;
}

// ─── Voice messages (Phase 2 — ephemeral, NOT replayed via EVENT) ───

export interface VoiceJoinMessage {
  type: 'VOICE_JOIN';
  payload: Record<string, never>;
}

export interface VoiceLeaveMessage {
  type: 'VOICE_LEAVE';
  payload: Record<string, never>;
}

export interface VoiceSignalMessage {
  type: 'VOICE_SIGNAL';
  payload: {
    toParticipantId: string;
    signalType: 'offer' | 'answer' | 'ice';
    data: Record<string, unknown>;
  };
}

// ─── Music Listen-Along messages (ephemeral, NOT replayed via EVENT) ───

export interface MusicBroadcastStartMessage {
  type: 'MUSIC_BROADCAST_START';
  payload: {
    platform: MusicPlatform;
    track: MusicTrack;
    positionMs: number;
    isPlaying: boolean;
  };
}

export interface MusicSyncMessage {
  type: 'MUSIC_SYNC';
  payload: {
    track: MusicTrack;
    positionMs: number;
    isPlaying: boolean;
  };
}

export interface MusicBroadcastStopMessage {
  type: 'MUSIC_BROADCAST_STOP';
  payload: Record<string, never>;
}

export interface MusicListenerJoinMessage {
  type: 'MUSIC_LISTENER_JOIN';
  payload: Record<string, never>;
}

export interface MusicListenerLeaveMessage {
  type: 'MUSIC_LISTENER_LEAVE';
  payload: Record<string, never>;
}

export type ClientMessage =
  | HelloMessage
  | LocUpdateMessage
  | SetDestinationMessage
  | ClearDestinationMessage
  | ChatMessageMessage
  | LeaveSessionMessage
  | VoiceJoinMessage
  | VoiceLeaveMessage
  | VoiceSignalMessage
  | MusicBroadcastStartMessage
  | MusicSyncMessage
  | MusicBroadcastStopMessage
  | MusicListenerJoinMessage
  | MusicListenerLeaveMessage;

// ─── Server → Client ───

export interface WelcomeMessage {
  type: 'WELCOME';
  payload: {
    connId: string;
    sessionId: string;
    participantId: string;
    hostParticipantId: string;
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

// ─── Server → Client voice messages (ephemeral, NOT replayed) ───

export interface ServerVoiceSignalMessage {
  type: 'VOICE_SIGNAL';
  payload: {
    fromParticipantId: string;
    signalType: 'offer' | 'answer' | 'ice';
    data: Record<string, unknown>;
  };
}

export interface VoiceStateMessage {
  type: 'VOICE_STATE';
  payload: {
    participantId: string;
    state: 'joined' | 'left';
  };
}

// ─── Server → Client music messages (ephemeral, NOT replayed) ───

export interface MusicStateMessage {
  type: 'MUSIC_STATE';
  payload: {
    broadcast: MusicBroadcast | null;
    listeners: string[]; // participantIds
  };
}

export interface MusicSyncBroadcastMessage {
  type: 'MUSIC_SYNC_BROADCAST';
  payload: {
    track: MusicTrack;
    positionMs: number;
    isPlaying: boolean;
    updatedAt: number;
  };
}

export type ServerMessage =
  | WelcomeMessage
  | SnapshotMessage
  | EventsMessage
  | ErrorMessage
  | ServerVoiceSignalMessage
  | VoiceStateMessage
  | MusicStateMessage
  | MusicSyncBroadcastMessage;

// ─── Event types (broadcast) ───

export type EventKind =
  | 'PARTICIPANT_JOINED'
  | 'PARTICIPANT_LEFT'
  | 'LOCATION_UPDATED'
  | 'DESTINATION_SET'
  | 'DESTINATION_CLEARED'
  | 'CHAT_MESSAGE';

export interface BaseEvent {
  eventId: number;
  ts: number; // server epoch ms
  kind: EventKind;
}

export interface ParticipantJoinedEvent extends BaseEvent {
  kind: 'PARTICIPANT_JOINED';
  data: { participantId: string; displayName: string | null };
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
    setBy: string; // participantId of who set it
  };
}

export interface DestinationClearedEvent extends BaseEvent {
  kind: 'DESTINATION_CLEARED';
  data: {
    clearedBy: string; // participantId
  };
}

export interface ChatMessageEvent extends BaseEvent {
  kind: 'CHAT_MESSAGE';
  data: {
    participantId: string;
    displayName: string | null;
    text: string;
  };
}

export type SessionEvent =
  | ParticipantJoinedEvent
  | ParticipantLeftEvent
  | LocationUpdatedEvent
  | DestinationSetEvent
  | DestinationClearedEvent
  | ChatMessageEvent;

// ─── Error codes ───

export type ErrorCode = 'BAD_MESSAGE' | 'UNAUTHORIZED' | 'NOT_IN_SESSION' | 'RATE_LIMITED' | 'FORBIDDEN';
