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
  const res = await fetch(`${API_URL}/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ displayName }),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Create session failed: ${res.status}`);
  }
  return res.json();
}

export async function joinSession(
  joinCode: string,
  displayName: string,
): Promise<JoinSessionResponse> {
  const res = await fetch(`${API_URL}/sessions/join`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ joinCode, displayName }),
  });
  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Join session failed: ${res.status}`);
  }
  return res.json();
}
