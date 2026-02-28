// Client-side session state using zustand.

import { create } from 'zustand';

export interface Participant {
  participantId: string;
  displayName: string | null;
  lastLocation: {
    lat: number;
    lng: number;
    speed?: number | null;
    heading?: number | null;
    accuracy?: number | null;
    ts?: number;
  } | null;
  status: string;
  lastSeenTs: number;
}

export interface Destination {
  lat: number;
  lng: number;
  label: string | null;
}

export interface ChatMessage {
  eventId: number;
  participantId: string;
  displayName: string | null;
  text: string;
  ts: number;
}

interface SessionState {
  // Auth / identity
  sessionId: string | null;
  participantId: string | null;
  token: string | null;
  joinCode: string | null;
  displayName: string | null;

  // Connection
  connected: boolean;
  lastEventId: number;
  reconnectCount: number;

  // Session data
  participants: Map<string, Participant>;
  destination: Destination | null;
  chatMessages: ChatMessage[];
  hostParticipantId: string | null;
  isHost: boolean;

  // Voice chat (Phase 2)
  voiceMembers: Set<string>;

  // Actions
  setSession: (s: {
    sessionId: string;
    participantId: string;
    token: string;
    joinCode?: string;
    displayName?: string;
    hostParticipantId?: string;
  }) => void;
  setConnected: (c: boolean) => void;
  setHostParticipantId: (id: string) => void;
  incrementReconnectCount: () => void;
  applySnapshot: (snapshot: {
    latestEventId: number;
    destination: Destination | null;
    participants: Array<Participant>;
  }) => void;
  applyEvent: (event: {
    eventId: number;
    kind: string;
    data: Record<string, unknown>;
    ts: number;
  }) => void;
  addVoiceMember: (participantId: string) => void;
  removeVoiceMember: (participantId: string) => void;
  reset: () => void;
}

export const useSessionStore = create<SessionState>((set, get) => ({
  sessionId: null,
  participantId: null,
  token: null,
  joinCode: null,
  displayName: null,
  connected: false,
  lastEventId: 0,
  reconnectCount: 0,
  participants: new Map(),
  destination: null,
  chatMessages: [],
  hostParticipantId: null,
  isHost: false,
  voiceMembers: new Set(),

  setSession: (s) => {
    const isHost = s.hostParticipantId ? s.participantId === s.hostParticipantId : false;
    set({
      sessionId: s.sessionId,
      participantId: s.participantId,
      token: s.token,
      joinCode: s.joinCode ?? null,
      displayName: s.displayName ?? null,
      hostParticipantId: s.hostParticipantId ?? null,
      isHost,
    });
  },

  setConnected: (c) => set({ connected: c }),

  setHostParticipantId: (id) => {
    const state = get();
    set({
      hostParticipantId: id,
      isHost: state.participantId === id,
    });
  },

  incrementReconnectCount: () => set((s) => ({ reconnectCount: s.reconnectCount + 1 })),

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
        const existing = participants.get(pid);
        if (existing) {
          participants.set(pid, { ...existing, status: 'online', lastSeenTs: event.ts });
        } else {
          participants.set(pid, {
            participantId: pid,
            displayName: (data.displayName as string | null) ?? null,
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
      case 'DESTINATION_CLEARED': {
        set({ destination: null });
        break;
      }
      case 'CHAT_MESSAGE': {
        const chatMessages = [...state.chatMessages];
        chatMessages.push({
          eventId: event.eventId,
          participantId: data.participantId as string,
          displayName: (data.displayName as string | null) ?? null,
          text: data.text as string,
          ts: event.ts,
        });
        // Keep last 200 messages in memory
        if (chatMessages.length > 200) {
          chatMessages.splice(0, chatMessages.length - 200);
        }
        set({ chatMessages });
        break;
      }
    }

    set({ participants, lastEventId: event.eventId });
  },

  addVoiceMember: (participantId) => {
    const voiceMembers = new Set(get().voiceMembers);
    voiceMembers.add(participantId);
    set({ voiceMembers });
  },

  removeVoiceMember: (participantId) => {
    const voiceMembers = new Set(get().voiceMembers);
    voiceMembers.delete(participantId);
    set({ voiceMembers });
  },

  reset: () =>
    set({
      sessionId: null,
      participantId: null,
      token: null,
      joinCode: null,
      displayName: null,
      connected: false,
      lastEventId: 0,
      reconnectCount: 0,
      participants: new Map(),
      destination: null,
      chatMessages: [],
      hostParticipantId: null,
      isHost: false,
      voiceMembers: new Set(),
    }),
}));
