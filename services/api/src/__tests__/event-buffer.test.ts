import { describe, it, expect, beforeEach } from 'vitest';
import { EventBuffer } from '../state/event-buffer.js';
import type { SessionEvent, ParticipantJoinedEvent } from '@waypoints/shared';

function makeEvent(eventId: number): SessionEvent {
  return {
    eventId,
    ts: Date.now(),
    kind: 'PARTICIPANT_JOINED',
    data: { participantId: `p-${eventId}`, displayName: null },
  } as ParticipantJoinedEvent;
}

describe('EventBuffer', () => {
  let buffer: EventBuffer;

  beforeEach(() => {
    buffer = new EventBuffer(5);
  });

  it('starts empty', () => {
    expect(buffer.size).toBe(0);
    expect(buffer.oldestEventId()).toBe(0);
    expect(buffer.newestEventId()).toBe(0);
  });

  it('pushes events and tracks size', () => {
    buffer.push(makeEvent(1));
    buffer.push(makeEvent(2));
    expect(buffer.size).toBe(2);
    expect(buffer.oldestEventId()).toBe(1);
    expect(buffer.newestEventId()).toBe(2);
  });

  it('evicts oldest when at capacity', () => {
    for (let i = 1; i <= 7; i++) {
      buffer.push(makeEvent(i));
    }
    expect(buffer.size).toBe(5);
    expect(buffer.oldestEventId()).toBe(3);
    expect(buffer.newestEventId()).toBe(7);
  });

  it('getRange returns events in (from, to] range', () => {
    for (let i = 1; i <= 5; i++) {
      buffer.push(makeEvent(i));
    }
    const range = buffer.getRange(2, 4);
    expect(range.map((e) => e.eventId)).toEqual([3, 4]);
  });

  it('getRange returns empty for out-of-range', () => {
    for (let i = 1; i <= 3; i++) {
      buffer.push(makeEvent(i));
    }
    expect(buffer.getRange(5, 10)).toEqual([]);
  });

  it('getRange handles full range', () => {
    for (let i = 1; i <= 5; i++) {
      buffer.push(makeEvent(i));
    }
    const range = buffer.getRange(0, 5);
    expect(range.map((e) => e.eventId)).toEqual([1, 2, 3, 4, 5]);
  });

  it('clear empties the buffer', () => {
    buffer.push(makeEvent(1));
    buffer.clear();
    expect(buffer.size).toBe(0);
    expect(buffer.oldestEventId()).toBe(0);
  });
});
