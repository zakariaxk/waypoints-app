// HTTP client for session create/join.

import { API_URL } from '../utils/constants';

export interface CreateSessionResponse {
  sessionId: string;
  joinCode: string;
  participantId: string;
  token: string;
}

export interface JoinSessionResponse {
  sessionId: string;
  participantId: string;
  token: string;
}

export async function createSession(displayName: string): Promise<CreateSessionResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const res = await fetch(`${API_URL}/sessions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ displayName }),
      signal: controller.signal,
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.error || `Create session failed: ${res.status}`);
    }
    return res.json();
  } finally {
    clearTimeout(timeout);
  }
}

export async function joinSession(
  joinCode: string,
  displayName: string,
): Promise<JoinSessionResponse> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 10_000);
  try {
    const res = await fetch(`${API_URL}/sessions/join`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ joinCode, displayName }),
      signal: controller.signal,
    });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body.error || `Join session failed: ${res.status}`);
    }
    return res.json();
  } finally {
    clearTimeout(timeout);
  }
}
