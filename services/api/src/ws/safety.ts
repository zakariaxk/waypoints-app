// RAISE_SOS / CLEAR_SOS / ARRIVAL_PING handlers (Phase 3).
//
// Unlike voice, these are DURABLE: they are pushed onto the ordered event
// stream, buffered for replay, and reflected in SNAPSHOT. A participant who
// reconnects must learn that an SOS is still active — missing one of these is
// exactly the case where missing a message matters.
//
// See docs/SPEC-PHASE3.md §5.2–5.3 and docs/WS-PROTOCOL.md.

import type { ValidatedRaiseSosPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';
import { haversineMeters } from '../utils/geo.js';
import { config } from '../config.js';

function sendError(
  conn: ConnState,
  code: 'BAD_MESSAGE' | 'NOT_ARRIVED' | 'FORBIDDEN',
  message: string,
): void {
  sendJson(conn.ws, { type: 'ERROR', payload: { code, message } });
}

export function handleRaiseSos(conn: ConnState, payload: ValidatedRaiseSosPayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  const note = payload.note?.trim() ? payload.note.trim() : null;
  const entry = sessionStore.raiseSos(sessionId, participantId, note);
  if (!entry) return;

  participant.lastSeenTs = Date.now();

  // Location is taken from server-held state, never from the client. A panic
  // signal is exactly the message you would not want a client to be able to
  // put an arbitrary position on. Null when the sender has not reported a
  // location yet — the client skips the camera-snap in that case rather than
  // rejecting the SOS (SPEC-PHASE3 §9 Q2).
  const loc = participant.lastLocation;

  const event = sessionStore.pushEvent(sessionId, 'SOS_RAISED', {
    participantId,
    note,
    lat: loc?.lat ?? null,
    lng: loc?.lng ?? null,
    ts: entry.ts,
  });

  if (event) {
    conn.log.info({ participantId }, 'SOS raised');
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}

export function handleClearSos(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  // Only ever clears the sender's own SOS — the participantId comes from the
  // authenticated connection, not from the payload, so there is no way to
  // address someone else's.
  const wasActive = sessionStore.clearSos(sessionId, participantId);
  if (!wasActive) return; // no-op, not an error

  const event = sessionStore.pushEvent(sessionId, 'SOS_CLEARED', { participantId });
  if (event) {
    conn.log.info({ participantId }, 'SOS cleared');
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}

export function handleArrivalPing(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  const participant = sessionStore.getParticipant(sessionId, participantId);
  if (!participant) return;

  if (!session.destination) {
    sendError(conn, 'BAD_MESSAGE', 'No destination is set for this session');
    return;
  }

  if (!participant.lastLocation) {
    sendError(conn, 'NOT_ARRIVED', 'No known location for this participant yet');
    return;
  }

  const distanceM = haversineMeters(
    participant.lastLocation.lat,
    participant.lastLocation.lng,
    session.destination.lat,
    session.destination.lng,
  );

  if (distanceM > config.arrivalRadiusM) {
    sendError(
      conn,
      'NOT_ARRIVED',
      `You are ${Math.round(distanceM)}m from the destination (within ${config.arrivalRadiusM}m required)`,
    );
    return;
  }

  // Idempotent: a second ping for the same destination is a no-op, not an
  // error. The client auto-fires this on arrival detection, so a duplicate is
  // an expected outcome of a jittery GPS fix rather than a client bug.
  if (!sessionStore.markArrived(sessionId, participantId)) return;

  participant.lastSeenTs = Date.now();

  const event = sessionStore.pushEvent(sessionId, 'ARRIVAL_PINGED', {
    participantId,
    ts: Date.now(),
  });

  if (event) {
    conn.log.info({ participantId }, 'arrival pinged');
    broadcastToSession(sessionId, { type: 'EVENT', payload: event });
  }
}
