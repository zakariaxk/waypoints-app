// Music listen-along service: start/stop broadcast, join/leave as listener, sync updates.
// Uses the existing WS client to send MUSIC_* messages.

import { sendJson, onMessage } from './ws-client';
import type { MusicPlatform, MusicTrack, MusicBroadcast } from '../state/session-store';

export interface MusicStateEvent {
  broadcast: MusicBroadcast | null;
  listeners: string[];
}

export interface MusicSyncEvent {
  track: MusicTrack;
  positionMs: number;
  isPlaying: boolean;
  updatedAt: number;
}

type MusicStateHandler = (event: MusicStateEvent) => void;
type MusicSyncHandler = (event: MusicSyncEvent) => void;

let musicStateHandlers: MusicStateHandler[] = [];
let musicSyncHandlers: MusicSyncHandler[] = [];
let unsubWs: (() => void) | null = null;

/** Start listening for MUSIC_* messages from the WS client. */
export function initMusicListeners(): () => void {
  if (unsubWs) return unsubWs; // already initialized

  unsubWs = onMessage((msg: unknown) => {
    const m = msg as { type?: string; payload?: Record<string, unknown> };
    if (!m.type || !m.payload) return;

    if (m.type === 'MUSIC_STATE') {
      const event = m.payload as unknown as MusicStateEvent;
      for (const handler of musicStateHandlers) {
        handler(event);
      }
    } else if (m.type === 'MUSIC_SYNC_BROADCAST') {
      const event = m.payload as unknown as MusicSyncEvent;
      for (const handler of musicSyncHandlers) {
        handler(event);
      }
    }
  });

  return () => {
    if (unsubWs) {
      unsubWs();
      unsubWs = null;
    }
  };
}

/** Start broadcasting music to the session. Only one person can broadcast at a time. */
export function startBroadcast(
  platform: MusicPlatform,
  track: MusicTrack,
  positionMs: number,
  isPlaying: boolean,
): void {
  sendJson({
    type: 'MUSIC_BROADCAST_START',
    payload: { platform, track, positionMs, isPlaying },
  });
}

/** Send a sync update (track change, position, play/pause). Only the broadcaster can call this. */
export function syncBroadcast(track: MusicTrack, positionMs: number, isPlaying: boolean): void {
  sendJson({
    type: 'MUSIC_SYNC',
    payload: { track, positionMs, isPlaying },
  });
}

/** Stop broadcasting music. Only the broadcaster can call this. */
export function stopBroadcast(): void {
  sendJson({ type: 'MUSIC_BROADCAST_STOP', payload: {} });
}

/** Join as a listener to the current broadcast. */
export function joinAsListener(): void {
  sendJson({ type: 'MUSIC_LISTENER_JOIN', payload: {} });
}

/** Leave as a listener. */
export function leaveAsListener(): void {
  sendJson({ type: 'MUSIC_LISTENER_LEAVE', payload: {} });
}

/** Subscribe to MUSIC_STATE events. Returns unsubscribe function. */
export function onMusicState(handler: MusicStateHandler): () => void {
  musicStateHandlers.push(handler);
  return () => {
    musicStateHandlers = musicStateHandlers.filter((h) => h !== handler);
  };
}

/** Subscribe to MUSIC_SYNC_BROADCAST events. Returns unsubscribe function. */
export function onMusicSync(handler: MusicSyncHandler): () => void {
  musicSyncHandlers.push(handler);
  return () => {
    musicSyncHandlers = musicSyncHandlers.filter((h) => h !== handler);
  };
}
