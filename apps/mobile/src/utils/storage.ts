// Persistent storage for user preferences and session history.

import AsyncStorage from '@react-native-async-storage/async-storage';

const KEYS = {
  DISPLAY_NAME: '@waypoints/displayName',
  SESSION_HISTORY: '@waypoints/sessionHistory',
} as const;

// ─── Display Name ───

export async function getStoredDisplayName(): Promise<string | null> {
  try {
    return await AsyncStorage.getItem(KEYS.DISPLAY_NAME);
  } catch {
    return null;
  }
}

export async function setStoredDisplayName(name: string): Promise<void> {
  try {
    await AsyncStorage.setItem(KEYS.DISPLAY_NAME, name);
  } catch {
    // Non-critical — ignore
  }
}

// ─── Session History ───

export interface SessionHistoryEntry {
  sessionId: string;
  joinCode: string;
  participantId: string;
  token: string;
  displayName: string | null;
  hostParticipantId: string | null;
  joinedAt: number;
  lastActiveAt: number;
}

const MAX_HISTORY = 10;

export async function getSessionHistory(): Promise<SessionHistoryEntry[]> {
  try {
    const raw = await AsyncStorage.getItem(KEYS.SESSION_HISTORY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as SessionHistoryEntry[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export async function addSessionToHistory(entry: SessionHistoryEntry): Promise<void> {
  try {
    const history = await getSessionHistory();
    // Remove existing entry for same session
    const filtered = history.filter((h) => h.sessionId !== entry.sessionId);
    filtered.unshift(entry);
    // Keep only recent sessions
    const trimmed = filtered.slice(0, MAX_HISTORY);
    await AsyncStorage.setItem(KEYS.SESSION_HISTORY, JSON.stringify(trimmed));
  } catch {
    // Non-critical
  }
}

export async function updateSessionActivity(sessionId: string): Promise<void> {
  try {
    const history = await getSessionHistory();
    const entry = history.find((h) => h.sessionId === sessionId);
    if (entry) {
      entry.lastActiveAt = Date.now();
      await AsyncStorage.setItem(KEYS.SESSION_HISTORY, JSON.stringify(history));
    }
  } catch {
    // Non-critical
  }
}

export async function removeSessionFromHistory(sessionId: string): Promise<void> {
  try {
    const history = await getSessionHistory();
    const filtered = history.filter((h) => h.sessionId !== sessionId);
    await AsyncStorage.setItem(KEYS.SESSION_HISTORY, JSON.stringify(filtered));
  } catch {
    // Non-critical
  }
}

export async function clearSessionHistory(): Promise<void> {
  try {
    await AsyncStorage.removeItem(KEYS.SESSION_HISTORY);
  } catch {
    // Non-critical
  }
}
