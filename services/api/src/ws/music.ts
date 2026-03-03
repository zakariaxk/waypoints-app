// MUSIC_BROADCAST_START / MUSIC_SYNC / MUSIC_BROADCAST_STOP / MUSIC_LISTENER_JOIN / MUSIC_LISTENER_LEAVE handlers.
// Music messages are EPHEMERAL — they are NOT emitted as EVENT,
// NOT stored in the event ring buffer, and NOT replayed on reconnect.
// Clients must re-join as listeners by sending MUSIC_LISTENER_JOIN after WELCOME/SNAPSHOT.

import type { ValidatedMusicBroadcastStartPayload, ValidatedMusicSyncPayload } from '@waypoints/shared';
import type { ConnState } from './handler.js';
import { sendJson, broadcastToSession } from './handler.js';
import { sessionStore } from '../state/session-store.js';

function sendError(conn: ConnState, code: 'BAD_MESSAGE' | 'FORBIDDEN', message: string): void {
  sendJson(conn.ws, { type: 'ERROR', payload: { code, message } });
}

/** Broadcast current music state to all session participants. */
function broadcastMusicState(sessionId: string): void {
  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  broadcastToSession(sessionId, {
    type: 'MUSIC_STATE',
    payload: {
      broadcast: session.musicBroadcast,
      listeners: Array.from(session.musicListeners),
    },
  });
}

/** Broadcast sync update to all listeners (not broadcasted to non-listeners). */
function broadcastSyncToListeners(sessionId: string): void {
  const session = sessionStore.getSession(sessionId);
  if (!session || !session.musicBroadcast) return;

  const { track, positionMs, isPlaying, updatedAt } = session.musicBroadcast;

  // Send MUSIC_SYNC_BROADCAST to all listeners
  const syncMessage = {
    type: 'MUSIC_SYNC_BROADCAST',
    payload: { track, positionMs, isPlaying, updatedAt },
  };

  // We broadcast to all participants - clients filter based on whether they're listening
  broadcastToSession(sessionId, syncMessage);
}

export function handleMusicBroadcastStart(conn: ConnState, payload: ValidatedMusicBroadcastStartPayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Only allow if no one is currently broadcasting
  if (session.musicBroadcast !== null) {
    sendError(conn, 'FORBIDDEN', 'Another user is already broadcasting music');
    return;
  }

  // Start the broadcast
  session.musicBroadcast = {
    broadcasterId: participantId,
    platform: payload.platform,
    track: payload.track,
    positionMs: payload.positionMs,
    isPlaying: payload.isPlaying,
    updatedAt: Date.now(),
  };

  // Broadcaster is automatically a listener
  session.musicListeners.add(participantId);

  // Broadcast MUSIC_STATE to all session participants
  broadcastMusicState(sessionId);
}

export function handleMusicSync(conn: ConnState, payload: ValidatedMusicSyncPayload): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Only the current broadcaster can send sync updates
  if (!session.musicBroadcast || session.musicBroadcast.broadcasterId !== participantId) {
    sendError(conn, 'FORBIDDEN', 'Only the broadcaster can send sync updates');
    return;
  }

  // Update the broadcast state
  session.musicBroadcast.track = payload.track;
  session.musicBroadcast.positionMs = payload.positionMs;
  session.musicBroadcast.isPlaying = payload.isPlaying;
  session.musicBroadcast.updatedAt = Date.now();

  // Broadcast sync to all participants (listeners will consume it)
  broadcastSyncToListeners(sessionId);
}

export function handleMusicBroadcastStop(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Only the current broadcaster can stop
  if (!session.musicBroadcast || session.musicBroadcast.broadcasterId !== participantId) {
    sendError(conn, 'FORBIDDEN', 'Only the broadcaster can stop the broadcast');
    return;
  }

  // Stop the broadcast
  session.musicBroadcast = null;
  session.musicListeners.clear();

  // Broadcast updated state (null broadcast)
  broadcastMusicState(sessionId);
}

export function handleMusicListenerJoin(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // Can only join if there's an active broadcast
  if (!session.musicBroadcast) {
    sendError(conn, 'BAD_MESSAGE', 'No active music broadcast to join');
    return;
  }

  session.musicListeners.add(participantId);

  // Broadcast updated MUSIC_STATE to all
  broadcastMusicState(sessionId);
}

export function handleMusicListenerLeave(conn: ConnState): void {
  const { sessionId, participantId } = conn;
  if (!sessionId || !participantId) return;

  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // If the broadcaster leaves as listener, stop the broadcast entirely
  if (session.musicBroadcast && session.musicBroadcast.broadcasterId === participantId) {
    session.musicBroadcast = null;
    session.musicListeners.clear();
  } else {
    session.musicListeners.delete(participantId);
  }

  // Broadcast updated state
  broadcastMusicState(sessionId);
}

/** Clean up music state when a participant disconnects or leaves the session. */
export function cleanupMusicMember(sessionId: string, participantId: string): void {
  const session = sessionStore.getSession(sessionId);
  if (!session) return;

  // If the broadcaster disconnects, end the broadcast
  if (session.musicBroadcast && session.musicBroadcast.broadcasterId === participantId) {
    session.musicBroadcast = null;
    session.musicListeners.clear();
    broadcastMusicState(sessionId);
  } else if (session.musicListeners.delete(participantId)) {
    // If a listener disconnects, just remove them
    broadcastMusicState(sessionId);
  }
}
