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

export const clientMessageSchema = z.discriminatedUnion('type', [
  helloMessageSchema,
  locUpdateMessageSchema,
  setDestinationMessageSchema,
]);

// ─── Type inference helpers ───

export type ValidatedHelloPayload = z.infer<typeof helloPayloadSchema>;
export type ValidatedLocUpdatePayload = z.infer<typeof locUpdatePayloadSchema>;
export type ValidatedSetDestinationPayload = z.infer<typeof setDestinationPayloadSchema>;
export type ValidatedClientMessage = z.infer<typeof clientMessageSchema>;
