// Client-side session state using zustand.

import { create } from 'zustand';

export interface Participant {
  participantId: string;
  displayName: string | null;
  lastLocation: { lat: number; lng: number; speed?: number | null; heading?: number | null; accuracy?: number | null; ts?: number } | null;
  status: string;
  lastSeenTs: number;
}

export interface Destination {
  lat: number;
  lng: number;
  label: string | null;
}

interface SessionState {
  // Auth / identity
  sessionId: string | null;
  participantId: string | null;
  token: string | null;
  joinCode: string | null;

  // Connection
  connected: boolean;
  lastEventId: number;

  // Session data
  participants: Map<string, Participant>;
  destination: Destination | null;

  // Actions
  setSession: (s: { sessionId: string; participantId: string; token: string; joinCode?: string }) => void;
  setConnected: (c: boolean) => void;
  applySnapshot: (snapshot: {
    latestEventId: number;
    destination: Destination | null;
    participants: Array<Participant>;
  }) => void;
  applyEvent: (event: { eventId: number; kind: string; data: Record<string, unknown>; ts: number }) => void;
  reset: () => void;
}

export const useSessionStore = create<SessionState>((set, get) => ({
  sessionId: null,
  participantId: null,
  token: null,
  joinCode: null,
  connected: false,
  lastEventId: 0,
  participants: new Map(),
  destination: null,

  setSession: (s) =>
    set({
      sessionId: s.sessionId,
      participantId: s.participantId,
      token: s.token,
      joinCode: s.joinCode ?? null,
    }),

  setConnected: (c) => set({ connected: c }),

  applySnapshot: (snapshot) => {
    const participants = new Map<string, Participant>();
    for (const p of snapshot.participants) {
      participants.set(p.participantId, p);
    }
    set({
      lastEventId: snapshot.latestEventId,
      destination: snapshot.destination,
      participants,
    });
  },

  applyEvent: (event) => {
    const state = get();
    // Ignore duplicates
    if (event.eventId <= state.lastEventId) return;

    const participants = new Map(state.participants);
    const data = event.data;

    switch (event.kind) {
      case 'PARTICIPANT_JOINED': {
        const pid = data.participantId as string;
        if (!participants.has(pid)) {
          participants.set(pid, {
            participantId: pid,
            displayName: null,
            lastLocation: null,
            status: 'online',
            lastSeenTs: event.ts,
          });
        }
        break;
      }
      case 'PARTICIPANT_LEFT': {
        const pid = data.participantId as string;
        const p = participants.get(pid);
        if (p) {
          participants.set(pid, { ...p, status: 'offline' });
        }
        break;
      }
      case 'LOCATION_UPDATED': {
        const pid = data.participantId as string;
        const p = participants.get(pid);
        if (p) {
          participants.set(pid, {
            ...p,
            lastLocation: {
              lat: data.lat as number,
              lng: data.lng as number,
              speed: data.speed as number | null,
              heading: data.heading as number | null,
              accuracy: data.accuracy as number | null,
              ts: data.ts as number,
            },
            status: 'online',
            lastSeenTs: event.ts,
          });
        }
        break;
      }
      case 'DESTINATION_SET': {
        set({
          destination: {
            lat: data.lat as number,
            lng: data.lng as number,
            label: data.label as string | null,
          },
        });
        break;
      }
    }

    set({ participants, lastEventId: event.eventId });
  },

  reset: () =>
    set({
      sessionId: null,
      participantId: null,
      token: null,
      joinCode: null,
      connected: false,
      lastEventId: 0,
      participants: new Map(),
      destination: null,
    }),
}));
