// Event application in the session store.
//
// This is where the replay bug lived: applySnapshot advanced lastEventId to
// the snapshot's latestEventId, and applyEvent then rejected everything with
// eventId <= lastEventId — which is every event in the EVENTS replay batch
// that follows a SNAPSHOT. Chat missed during a disconnect was lost forever,
// while the README advertised "no missed updates".

import { describe, it, expect, beforeEach } from 'vitest';
import { useSessionStore } from './session-store';

type Event = { eventId: number; kind: string; data: Record<string, unknown>; ts: number };

function evt(eventId: number, kind: string, data: Record<string, unknown> = {}): Event {
  return { eventId, kind, data, ts: 1_700_000_000_000 + eventId };
}

function participant(participantId: string, displayName: string | null = null) {
  return {
    participantId,
    displayName,
    lastLocation: null,
    status: 'online',
    lastSeenTs: 0,
  };
}

beforeEach(() => {
  useSessionStore.getState().reset();
  useSessionStore.getState().setResyncHandler(null);
});

describe('applyEvents (reconnect replay)', () => {
  it('applies a replay batch whose ids are below the snapshot latestEventId', () => {
    const store = useSessionStore.getState();

    // Reconnect order on the wire: WELCOME, SNAPSHOT, EVENTS.
    store.applySnapshot({
      latestEventId: 10,
      destination: null,
      participants: [participant('alice', 'Alice'), participant('bob', 'Bob')],
    });
    expect(useSessionStore.getState().lastEventId).toBe(10);

    // The server computed these as exactly what we missed. Every id is <= 10.
    store.applyEvents([
      evt(7, 'CHAT_MESSAGE', { participantId: 'bob', displayName: 'Bob', text: 'missed you' }),
      evt(9, 'CHAT_MESSAGE', { participantId: 'bob', displayName: 'Bob', text: 'still here' }),
      evt(10, 'DESTINATION_SET', { lat: 1, lng: 2, label: 'Pub', setBy: 'alice' }),
    ]);

    const state = useSessionStore.getState();
    expect(state.chatMessages.map((m) => m.text)).toEqual(['missed you', 'still here']);
    expect(state.destination).toEqual({ lat: 1, lng: 2, label: 'Pub' });
  });

  it('does not duplicate a chat message already held locally', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 4, destination: null, participants: [participant('bob')] });
    store.applyEvents([evt(5, 'CHAT_MESSAGE', { participantId: 'bob', text: 'hi' })]);
    // Same event redelivered by a second replay (overlapping reconnects).
    store.applyEvents([evt(5, 'CHAT_MESSAGE', { participantId: 'bob', text: 'hi' })]);

    expect(useSessionStore.getState().chatMessages).toHaveLength(1);
  });

  it('leaves lastEventId at the highest applied id', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 3, destination: null, participants: [] });
    store.applyEvents([evt(4, 'PARTICIPANT_LEFT', { participantId: 'x' })]);
    expect(useSessionStore.getState().lastEventId).toBe(4);
  });
});

describe('applyEvent (live path)', () => {
  it('ignores an event already applied', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 5, destination: null, participants: [participant('bob')] });
    store.applyEvent(evt(5, 'CHAT_MESSAGE', { participantId: 'bob', text: 'dupe' }));
    expect(useSessionStore.getState().chatMessages).toHaveLength(0);
  });

  it('applies the next event in sequence', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 5, destination: null, participants: [participant('bob')] });
    store.applyEvent(evt(6, 'CHAT_MESSAGE', { participantId: 'bob', text: 'live' }));
    expect(useSessionStore.getState().chatMessages.map((m) => m.text)).toEqual(['live']);
    expect(useSessionStore.getState().lastEventId).toBe(6);
  });

  it('triggers a resync on a sequence gap instead of applying out of order', () => {
    const store = useSessionStore.getState();
    let resyncs = 0;
    store.setResyncHandler(() => {
      resyncs++;
    });
    store.applySnapshot({ latestEventId: 5, destination: null, participants: [participant('bob')] });

    // eventId 8 means 6 and 7 were missed. Applying it would advance
    // lastEventId past them and lose them permanently.
    store.applyEvent(evt(8, 'CHAT_MESSAGE', { participantId: 'bob', text: 'gap' }));

    expect(resyncs).toBe(1);
    expect(useSessionStore.getState().chatMessages).toHaveLength(0);
    expect(useSessionStore.getState().lastEventId).toBe(5);
  });

  it('applies a gapped event when no resync handler is registered', () => {
    // Degrading to "apply it anyway" beats dropping data on the floor when
    // there is no connection to resync.
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 5, destination: null, participants: [participant('bob')] });
    store.applyEvent(evt(8, 'CHAT_MESSAGE', { participantId: 'bob', text: 'gap' }));
    expect(useSessionStore.getState().chatMessages).toHaveLength(1);
  });
});

describe('safety events', () => {
  it('records and clears an SOS', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [participant('bob')] });

    store.applyEvent(
      evt(1, 'SOS_RAISED', { participantId: 'bob', note: 'help', lat: 1, lng: 2, ts: 123 }),
    );
    expect(useSessionStore.getState().activeSos.get('bob')).toMatchObject({
      note: 'help',
      lat: 1,
      lng: 2,
    });

    store.applyEvent(evt(2, 'SOS_CLEARED', { participantId: 'bob' }));
    expect(useSessionStore.getState().activeSos.has('bob')).toBe(false);
  });

  it('restores active SOS from a snapshot', () => {
    useSessionStore.getState().applySnapshot({
      latestEventId: 9,
      destination: null,
      participants: [participant('bob')],
      activeSos: [{ participantId: 'bob', note: 'still stuck', lat: null, lng: null, ts: 5 }],
    });
    expect(useSessionStore.getState().activeSos.get('bob')?.note).toBe('still stuck');
  });

  it('marks arrival and resets it when the destination changes', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [participant('bob')] });

    store.applyEvent(evt(1, 'ARRIVAL_PINGED', { participantId: 'bob', ts: 1 }));
    expect(useSessionStore.getState().participants.get('bob')?.arrived).toBe(true);

    store.applyEvent(evt(2, 'DESTINATION_SET', { lat: 9, lng: 9, label: 'New', setBy: 'alice' }));
    expect(useSessionStore.getState().participants.get('bob')?.arrived).toBe(false);
  });

  it('carries battery through LOCATION_UPDATED and keeps the last value when omitted', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [participant('bob')] });

    store.applyEvent(
      evt(1, 'LOCATION_UPDATED', {
        participantId: 'bob', lat: 1, lng: 2, speed: null, heading: null,
        accuracy: null, ts: 1, battery: 0.1, charging: false,
      }),
    );
    expect(useSessionStore.getState().participants.get('bob')?.battery).toBeCloseTo(0.1);

    store.applyEvent(
      evt(2, 'LOCATION_UPDATED', {
        participantId: 'bob', lat: 3, lng: 4, speed: null, heading: null,
        accuracy: null, ts: 2, battery: null, charging: null,
      }),
    );
    expect(useSessionStore.getState().participants.get('bob')?.battery).toBeCloseTo(0.1);
  });
});

describe('participant lifecycle', () => {
  it('marks a participant offline on PARTICIPANT_LEFT without dropping them', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [participant('bob')] });
    store.applyEvent(evt(1, 'PARTICIPANT_LEFT', { participantId: 'bob' }));

    const p = useSessionStore.getState().participants.get('bob');
    expect(p).toBeDefined();
    expect(p?.status).toBe('offline');
  });

  it('adds an unknown participant on PARTICIPANT_JOINED', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [] });
    store.applyEvent(evt(1, 'PARTICIPANT_JOINED', { participantId: 'zoe', displayName: 'Zoe' }));

    expect(useSessionStore.getState().participants.get('zoe')?.displayName).toBe('Zoe');
  });

  it('caps chat history at 200 messages', () => {
    const store = useSessionStore.getState();
    store.applySnapshot({ latestEventId: 0, destination: null, participants: [participant('bob')] });
    for (let i = 1; i <= 250; i++) {
      store.applyEvent(evt(i, 'CHAT_MESSAGE', { participantId: 'bob', text: `m${i}` }));
    }
    const msgs = useSessionStore.getState().chatMessages;
    expect(msgs).toHaveLength(200);
    expect(msgs[msgs.length - 1].text).toBe('m250');
  });
});
