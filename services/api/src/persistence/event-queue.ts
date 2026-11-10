import type { SessionEvent } from '@waypoints/shared';

export interface PersistenceRecord {
  table: 'profiles' | 'session_metadata' | 'session_memberships' | 'session_events';
  values: Record<string, unknown>;
}

export interface PersistenceTransport { insert(records: PersistenceRecord[]): Promise<void> }

/** Bounded, asynchronous batch queue. It is deliberately never awaited by the real-time path. */
export class PersistenceQueue {
  private pending: PersistenceRecord[] = [];
  private timer: NodeJS.Timeout | null = null;
  private flushing = false;

  constructor(private readonly transport: PersistenceTransport | null, private readonly batchSize = 100, private readonly flushMs = 500) {}

  enqueue(record: PersistenceRecord): void {
    if (!this.transport) return;
    this.pending.push(record);
    if (this.pending.length >= this.batchSize) void this.flush();
    else if (!this.timer) this.timer = setTimeout(() => void this.flush(), this.flushMs);
  }

  recordEvent(sessionId: string, actorUserId: string, event: SessionEvent): void {
    if (event.kind === 'LOCATION_UPDATED') return;
    this.enqueue({ table: 'session_events', values: {
      session_id: sessionId, actor_user_id: actorUserId, event_id: event.eventId,
      kind: event.kind, payload: event.data, occurred_at: new Date(event.ts).toISOString(),
    }});
  }

  async flush(): Promise<void> {
    if (!this.transport || this.flushing || this.pending.length === 0) return;
    if (this.timer) { clearTimeout(this.timer); this.timer = null; }
    this.flushing = true;
    const batch = this.pending.splice(0, this.batchSize);
    try { await this.transport.insert(batch); }
    catch { this.pending.unshift(...batch); }
    finally {
      this.flushing = false;
      if (this.pending.length) this.timer = setTimeout(() => void this.flush(), this.flushMs);
    }
  }

  get size(): number { return this.pending.length; }
  async close(): Promise<void> { if (this.timer) clearTimeout(this.timer); await this.flush(); }
}

export class SupabaseRestTransport implements PersistenceTransport {
  constructor(private readonly url: string, private readonly serviceKey: string, private readonly fetchImpl: typeof fetch = fetch) {}
  async insert(records: PersistenceRecord[]): Promise<void> {
    const groups = new Map<string, Record<string, unknown>[]>();
    for (const record of records) groups.set(record.table, [...(groups.get(record.table) ?? []), record.values]);
    for (const table of ['profiles', 'session_metadata', 'session_memberships', 'session_events'] as const) {
      const values = groups.get(table);
      if (!values?.length) continue;
      const response = await this.fetchImpl(`${this.url.replace(/\/$/, '')}/rest/v1/${table}`, {
        method: 'POST', headers: { apikey: this.serviceKey, Authorization: `Bearer ${this.serviceKey}`, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(values),
      });
      if (!response.ok) throw new Error(`Supabase insert ${table} failed: ${response.status}`);
    }
  }
}
