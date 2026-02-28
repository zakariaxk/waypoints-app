// Deep link utilities for handling waypoints:// URLs.
// URL format: waypoints://join/{joinCode}

import * as Linking from 'expo-linking';

/**
 * Parse a deep link URL to extract a join code.
 * Supports: waypoints://join/ABC123
 */
export function parseJoinCode(url: string): string | null {
  try {
    const parsed = Linking.parse(url);
    // Handle waypoints://join/CODE
    if (parsed.path?.startsWith('join/')) {
      const code = parsed.path.replace('join/', '').trim().toUpperCase();
      if (code.length >= 4 && code.length <= 10) return code;
    }
    // Handle waypoints://join?code=CODE
    if (parsed.path === 'join' && parsed.queryParams?.code) {
      const code = String(parsed.queryParams.code).trim().toUpperCase();
      if (code.length >= 4 && code.length <= 10) return code;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Generate a shareable deep link URL for a session.
 */
export function makeJoinLink(joinCode: string): string {
  return `waypoints://join/${joinCode}`;
}

/**
 * Get the initial URL that opened the app (cold start).
 */
export async function getInitialJoinCode(): Promise<string | null> {
  const url = await Linking.getInitialURL();
  if (!url) return null;
  return parseJoinCode(url);
}

/**
 * Subscribe to incoming deep links (warm start).
 */
export function onDeepLink(callback: (joinCode: string) => void): () => void {
  const subscription = Linking.addEventListener('url', (event) => {
    const code = parseJoinCode(event.url);
    if (code) callback(code);
  });
  return () => subscription.remove();
}
