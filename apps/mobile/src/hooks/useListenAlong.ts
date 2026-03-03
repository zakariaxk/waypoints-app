// useListenAlong — Music listen-along hook for Waypoints sessions.
// Allows one user to broadcast their music and others to join as listeners.

import { useEffect, useCallback, useMemo } from 'react';
import { useSessionStore, type MusicPlatform, type MusicTrack, type MusicBroadcast } from '../state/session-store';
import {
  initMusicListeners,
  startBroadcast,
  syncBroadcast,
  stopBroadcast,
  joinAsListener,
  leaveAsListener,
  onMusicState,
  onMusicSync,
} from '../services/music';

export interface ListenAlongState {
  /** Current active broadcast (null if no one is broadcasting). */
  broadcast: MusicBroadcast | null;
  /** List of participant IDs currently listening. */
  listeners: string[];
  /** Whether the current user is the broadcaster. */
  isBroadcaster: boolean;
  /** Whether the current user is listening (includes broadcaster). */
  isListening: boolean;
  /** Whether there's an active broadcast the user can join. */
  canJoin: boolean;
}

export interface ListenAlongActions {
  /** Start broadcasting music. Only works if no one else is broadcasting. */
  start: (platform: MusicPlatform, track: MusicTrack, positionMs: number, isPlaying: boolean) => void;
  /** Send a sync update (track change, position, play/pause). Only broadcaster can call. */
  sync: (track: MusicTrack, positionMs: number, isPlaying: boolean) => void;
  /** Stop broadcasting. Only broadcaster can call. */
  stop: () => void;
  /** Join as a listener to the current broadcast. */
  join: () => void;
  /** Leave as a listener (or stop broadcast if you're the broadcaster). */
  leave: () => void;
}

export function useListenAlong(sessionId: string | null): ListenAlongState & ListenAlongActions {
  const participantId = useSessionStore((s) => s.participantId);
  const musicBroadcast = useSessionStore((s) => s.musicBroadcast);
  const musicListeners = useSessionStore((s) => s.musicListeners);
  const setMusicState = useSessionStore((s) => s.setMusicState);
  const updateMusicSync = useSessionStore((s) => s.updateMusicSync);

  // Initialize music listeners when we have a session
  useEffect(() => {
    if (!sessionId) return;

    const cleanup = initMusicListeners();

    // Subscribe to MUSIC_STATE messages
    const unsubState = onMusicState((event) => {
      setMusicState(event.broadcast, event.listeners);
    });

    // Subscribe to MUSIC_SYNC_BROADCAST messages
    const unsubSync = onMusicSync((event) => {
      updateMusicSync(event.track, event.positionMs, event.isPlaying, event.updatedAt);
    });

    return () => {
      cleanup();
      unsubState();
      unsubSync();
    };
  }, [sessionId, setMusicState, updateMusicSync]);

  // Computed state
  const isBroadcaster = useMemo(
    () => musicBroadcast !== null && musicBroadcast.broadcasterId === participantId,
    [musicBroadcast, participantId],
  );

  const isListening = useMemo(
    () => participantId !== null && musicListeners.has(participantId),
    [musicListeners, participantId],
  );

  const canJoin = useMemo(
    () => musicBroadcast !== null && !isListening,
    [musicBroadcast, isListening],
  );

  const listeners = useMemo(() => Array.from(musicListeners), [musicListeners]);

  // Actions
  const start = useCallback(
    (platform: MusicPlatform, track: MusicTrack, positionMs: number, isPlaying: boolean) => {
      startBroadcast(platform, track, positionMs, isPlaying);
    },
    [],
  );

  const sync = useCallback((track: MusicTrack, positionMs: number, isPlaying: boolean) => {
    syncBroadcast(track, positionMs, isPlaying);
  }, []);

  const stop = useCallback(() => {
    stopBroadcast();
  }, []);

  const join = useCallback(() => {
    joinAsListener();
  }, []);

  const leave = useCallback(() => {
    if (isBroadcaster) {
      stopBroadcast();
    } else {
      leaveAsListener();
    }
  }, [isBroadcaster]);

  return {
    broadcast: musicBroadcast,
    listeners,
    isBroadcaster,
    isListening,
    canJoin,
    start,
    sync,
    stop,
    join,
    leave,
  };
}
