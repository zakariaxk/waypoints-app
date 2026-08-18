// Ring buffer for session events. Supports replay of missed events on reconnect.
//
// Backed by a fixed-size circular array rather than an Array + shift(). Once
// the buffer is full, shift() memmoves every remaining element on *every*
// event — an O(capacity) cost on the hottest path in the system (location
// updates at 1/sec/participant). The circular form makes push O(1).
//
// eventIds are monotonically increasing per session with no gaps, so the
// buffer is always sorted by eventId and a range query is a contiguous walk.

import type { SessionEvent } from '@waypoints/shared';

export class EventBuffer {
  private buffer: (SessionEvent | undefined)[];
  private capacity: number;
  /** Index of the next write. */
  private head = 0;
  /** Number of events currently held (≤ capacity). */
  private count = 0;

  constructor(capacity: number) {
    this.capacity = Math.max(1, capacity);
    this.buffer = new Array<SessionEvent | undefined>(this.capacity);
  }

  /** Push a new event. Overwrites the oldest once at capacity. */
  push(event: SessionEvent): void {
    this.buffer[this.head] = event;
    this.head = (this.head + 1) % this.capacity;
    if (this.count < this.capacity) this.count++;
  }

  /** Index into the backing array of the i-th oldest held event. */
  private indexOfOldest(offset: number): number {
    const start = (this.head - this.count + this.capacity) % this.capacity;
    return (start + offset) % this.capacity;
  }

  /** Lowest eventId still in the buffer, or 0 if empty. */
  oldestEventId(): number {
    if (this.count === 0) return 0;
    return this.buffer[this.indexOfOldest(0)]!.eventId;
  }

  /** Newest eventId in the buffer, or 0 if empty. */
  newestEventId(): number {
    if (this.count === 0) return 0;
    return this.buffer[this.indexOfOldest(this.count - 1)]!.eventId;
  }

  /**
   * Get events with eventId in range (fromExclusive, toInclusive].
   * Returns empty array if range is not satisfiable.
   */
  getRange(fromExclusive: number, toInclusive: number): SessionEvent[] {
    const result: SessionEvent[] = [];
    for (let i = 0; i < this.count; i++) {
      const event = this.buffer[this.indexOfOldest(i)]!;
      if (event.eventId > toInclusive) break; // sorted — nothing further qualifies
      if (event.eventId > fromExclusive) result.push(event);
    }
    return result;
  }

  /** Number of events currently buffered. */
  get size(): number {
    return this.count;
  }

  /** Clear all events. */
  clear(): void {
    this.buffer = new Array<SessionEvent | undefined>(this.capacity);
    this.head = 0;
    this.count = 0;
  }
}
