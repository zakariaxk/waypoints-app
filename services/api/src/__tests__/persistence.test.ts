import { createHmac } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { describe, expect, it, vi } from 'vitest';
import { SupabaseJwtVerifier } from '../auth/supabase-jwt.js';
import { PersistenceQueue, type PersistenceRecord, type PersistenceTransport } from '../persistence/event-queue.js';

function token(secret: string, claims: Record<string, unknown>): string {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signature = createHmac('sha256', secret).update(`${header}.${payload}`).digest('base64url');
  return `${header}.${payload}.${signature}`;
}

describe('Supabase persistence boundary', () => {
  it('verifies a valid Supabase JWT and rejects an invalid signature', async () => {
    const secret = 'test-secret';
    const verifier = new SupabaseJwtVerifier('https://project.supabase.co', secret);
    const claims = { sub: '5c70a09d-7059-4ebd-9c31-9c4ea8d5b74e', aud: 'authenticated', iss: 'https://project.supabase.co/auth/v1', exp: Math.floor(Date.now() / 1000) + 60, email: 'a@example.test' };
    await expect(verifier.verify(token(secret, claims))).resolves.toEqual({ userId: claims.sub, email: claims.email });
    await expect(verifier.verify(token('wrong-secret', claims))).resolves.toBeNull();
  });

  it('batches durable events and never queues a location update', async () => {
    const inserts: PersistenceRecord[][] = [];
    const transport: PersistenceTransport = { insert: vi.fn(async (rows) => { inserts.push(rows); }) };
    const queue = new PersistenceQueue(transport, 10, 60_000);
    queue.recordEvent('ad3c4551-99a8-4ccb-9e53-56699703df4b', '5c70a09d-7059-4ebd-9c31-9c4ea8d5b74e', { eventId: 1, ts: Date.now(), kind: 'LOCATION_UPDATED', data: { participantId: 'p', lat: 1, lng: 2, speed: null, heading: null, accuracy: null, ts: 1 } });
    queue.recordEvent('ad3c4551-99a8-4ccb-9e53-56699703df4b', '5c70a09d-7059-4ebd-9c31-9c4ea8d5b74e', { eventId: 2, ts: Date.now(), kind: 'CHAT_MESSAGE', data: { participantId: 'p', displayName: 'A', text: 'hi' } });
    expect(queue.size).toBe(1);
    await queue.flush();
    expect(inserts).toHaveLength(1);
    expect(inserts[0][0].table).toBe('session_events');
    await queue.close();
  });

  it('ships an RLS migration that excludes location history', async () => {
    const migration = await readFile(new URL('../../../../supabase/migrations/20260831000000_persistence_auth_and_event_history.sql', import.meta.url), 'utf8');
    for (const table of ['profiles', 'friendships', 'session_metadata', 'session_memberships', 'session_events']) {
      expect(migration).toContain(`alter table public.${table} enable row level security`);
    }
    expect(migration).toContain("kind in ('PARTICIPANT_JOINED', 'PARTICIPANT_LEFT', 'DESTINATION_SET', 'DESTINATION_CLEARED', 'CHAT_MESSAGE')");
    expect(migration).not.toContain('LOCATION_UPDATED');
  });
});
