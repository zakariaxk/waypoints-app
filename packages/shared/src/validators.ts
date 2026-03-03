// Zod validators for all inbound WS messages (client → server).
// Used by the backend dispatcher to validate before processing.

import { z } from 'zod';

// ─── Individual message schemas ───

export const helloPayloadSchema = z.object({
  sessionId: z.string().min(1),
  participantId: z.string().min(1),
  token: z.string().min(1),
  lastEventId: z.number().int().nonnegative().nullable(),
});

export const locUpdatePayloadSchema = z.object({
  seq: z.number().int().nonnegative(),
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  speed: z.number().nullable(),
  heading: z.number().nullable(),
  accuracy: z.number().nullable(),
  ts: z.number().positive(),
});

export const setDestinationPayloadSchema = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
  label: z.string().nullable(),
});

export const chatMessagePayloadSchema = z.object({
  text: z.string().min(1).max(500),
});

export const leaveSessionPayloadSchema = z.object({});

export const clearDestinationPayloadSchema = z.object({});

// ─── Voice message schemas (Phase 2) ───

export const voiceJoinPayloadSchema = z.object({});

export const voiceLeavePayloadSchema = z.object({});

export const voiceSignalPayloadSchema = z.object({
  toParticipantId: z.string().min(1),
  signalType: z.enum(['offer', 'answer', 'ice']),
  data: z.record(z.unknown()),
});

// ─── Music Listen-Along schemas ───

export const musicPlatformSchema = z.enum(['spotify', 'apple_music', 'soundcloud']);

export const musicTrackSchema = z.object({
  trackId: z.string().min(1),
  title: z.string().min(1).max(200),
  artist: z.string().min(1).max(200),
  albumArt: z.string().url().nullable(),
  durationMs: z.number().int().positive(),
});

export const musicBroadcastStartPayloadSchema = z.object({
  platform: musicPlatformSchema,
  track: musicTrackSchema,
  positionMs: z.number().int().nonnegative(),
  isPlaying: z.boolean(),
});

export const musicSyncPayloadSchema = z.object({
  track: musicTrackSchema,
  positionMs: z.number().int().nonnegative(),
  isPlaying: z.boolean(),
});

export const musicBroadcastStopPayloadSchema = z.object({});

export const musicListenerJoinPayloadSchema = z.object({});

export const musicListenerLeavePayloadSchema = z.object({});

// ─── Discriminated union for all client messages ───

export const helloMessageSchema = z.object({
  type: z.literal('HELLO'),
  payload: helloPayloadSchema,
});

export const locUpdateMessageSchema = z.object({
  type: z.literal('LOC_UPDATE'),
  payload: locUpdatePayloadSchema,
});

export const setDestinationMessageSchema = z.object({
  type: z.literal('SET_DESTINATION'),
  payload: setDestinationPayloadSchema,
});

export const chatMessageMessageSchema = z.object({
  type: z.literal('CHAT_MESSAGE'),
  payload: chatMessagePayloadSchema,
});

export const leaveSessionMessageSchema = z.object({
  type: z.literal('LEAVE_SESSION'),
  payload: leaveSessionPayloadSchema,
});

export const clearDestinationMessageSchema = z.object({
  type: z.literal('CLEAR_DESTINATION'),
  payload: clearDestinationPayloadSchema,
});

export const voiceJoinMessageSchema = z.object({
  type: z.literal('VOICE_JOIN'),
  payload: voiceJoinPayloadSchema,
});

export const voiceLeaveMessageSchema = z.object({
  type: z.literal('VOICE_LEAVE'),
  payload: voiceLeavePayloadSchema,
});

export const voiceSignalMessageSchema = z.object({
  type: z.literal('VOICE_SIGNAL'),
  payload: voiceSignalPayloadSchema,
});

export const musicBroadcastStartMessageSchema = z.object({
  type: z.literal('MUSIC_BROADCAST_START'),
  payload: musicBroadcastStartPayloadSchema,
});

export const musicSyncMessageSchema = z.object({
  type: z.literal('MUSIC_SYNC'),
  payload: musicSyncPayloadSchema,
});

export const musicBroadcastStopMessageSchema = z.object({
  type: z.literal('MUSIC_BROADCAST_STOP'),
  payload: musicBroadcastStopPayloadSchema,
});

export const musicListenerJoinMessageSchema = z.object({
  type: z.literal('MUSIC_LISTENER_JOIN'),
  payload: musicListenerJoinPayloadSchema,
});

export const musicListenerLeaveMessageSchema = z.object({
  type: z.literal('MUSIC_LISTENER_LEAVE'),
  payload: musicListenerLeavePayloadSchema,
});

export const clientMessageSchema = z.discriminatedUnion('type', [
  helloMessageSchema,
  locUpdateMessageSchema,
  setDestinationMessageSchema,
  clearDestinationMessageSchema,
  chatMessageMessageSchema,
  leaveSessionMessageSchema,
  voiceJoinMessageSchema,
  voiceLeaveMessageSchema,
  voiceSignalMessageSchema,
  musicBroadcastStartMessageSchema,
  musicSyncMessageSchema,
  musicBroadcastStopMessageSchema,
  musicListenerJoinMessageSchema,
  musicListenerLeaveMessageSchema,
]);

// ─── Type inference helpers ───

export type ValidatedHelloPayload = z.infer<typeof helloPayloadSchema>;
export type ValidatedLocUpdatePayload = z.infer<typeof locUpdatePayloadSchema>;
export type ValidatedSetDestinationPayload = z.infer<typeof setDestinationPayloadSchema>;
export type ValidatedChatMessagePayload = z.infer<typeof chatMessagePayloadSchema>;
export type ValidatedVoiceSignalPayload = z.infer<typeof voiceSignalPayloadSchema>;
export type ValidatedMusicBroadcastStartPayload = z.infer<typeof musicBroadcastStartPayloadSchema>;
export type ValidatedMusicSyncPayload = z.infer<typeof musicSyncPayloadSchema>;
export type ValidatedClientMessage = z.infer<typeof clientMessageSchema>;
