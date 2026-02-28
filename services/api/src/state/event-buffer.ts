// Ring buffer for session events. Supports replay of missed events on reconnect.

import type { SessionEvent } from '@waypoints/shared';

export class EventBuffer {
  private buffer: SessionEvent[] = [];
  private capacity: number;

  constructor(capacity: number) {
    this.capacity = capacity;
  }

  /** Push a new event. Drops oldest if at capacity. */
  push(event: SessionEvent): void {
    if (this.buffer.length >= this.capacity) {
      this.buffer.shift();
    }
    this.buffer.push(event);
  }

  /** Lowest eventId still in the buffer, or 0 if empty. */
  oldestEventId(): number {
    return this.buffer.length > 0 ? this.buffer[0].eventId : 0;
  }

  /** Newest eventId in the buffer, or 0 if empty. */
  newestEventId(): number {
    return this.buffer.length > 0 ? this.buffer[this.buffer.length - 1].eventId : 0;
  }

  /**
   * Get events with eventId in range (fromExclusive, toInclusive].
   * Returns empty array if range is not satisfiable.
   */
  getRange(fromExclusive: number, toInclusive: number): SessionEvent[] {
    return this.buffer.filter((e) => e.eventId > fromExclusive && e.eventId <= toInclusive);
  }

  /** Number of events currently buffered. */
  get size(): number {
    return this.buffer.length;
  }

  /** Clear all events. */
  clear(): void {
    this.buffer = [];
  }
}
