// Presence logic: periodic sweep to mark participants stale or offline.

import { config } from '../config.js';
import type { FullSessionState } from './session-store.js';

/** Update presence statuses for all participants in a session. */
export function updatePresenceForSession(session: FullSessionState): void {
  const now = Date.now();
  const staleMs = config.staleThresholdSec * 1000;
  const offlineMs = config.offlineThresholdSec * 1000;

  for (const participant of session.participants.values()) {
    if (participant.connId === null) {
      participant.status = 'offline';
      continue;
    }

    const elapsed = now - participant.lastSeenTs;
    if (elapsed > offlineMs) {
      participant.status = 'offline';
    } else if (elapsed > staleMs) {
      participant.status = 'stale';
    } else {
      participant.status = 'online';
    }
  }
}

