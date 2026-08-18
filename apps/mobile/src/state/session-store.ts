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
  /** 0..1, latest reported. Phase 3 presence enrichment. */
  battery?: number | null;
  charging?: boolean | null;
  /** True once this participant has pinged arrival at the destination. */
  arrived?: boolean;
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

/** An active SOS as tracked client-side. */
export interface ActiveSos {
  participantId: string;
  note: string | null;
  lat: number | null;
  lng: number | null;
  ts: number;
}

interface ServerEvent {
  eventId: number;
  kind: string;
  data: Record<string, unknown>;
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
  /**
   * Set when the server rejects us in a way retrying cannot fix (bad token,
   * session gone). Distinct from `connected: false`, which is transient —
   * conflating them left a dead session showing "reconnecting..." forever.
   */
  sessionInvalid: boolean;
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

  // Safety (Phase 3)
  activeSos: Map<string, ActiveSos>;

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
  setSessionInvalid: (v: boolean) => void;
  setHostParticipantId: (id: string) => void;
  incrementReconnectCount: () => void;
  applySnapshot: (snapshot: {
    latestEventId: number;
    destination: Destination | null;
    participants: Array<Participant>;
    activeSos?: ActiveSos[];
  }) => void;
  applyEvent: (event: ServerEvent) => void;
  /**
   * Apply a server-computed replay batch (the `EVENTS` message).
   *
   * Applied unconditionally: the server already determined exactly which
   * events this client missed, from the `lastEventId` it sent in HELLO.
   * Routing them through `applyEvent`'s live-path dedup would discard every
   * one of them, because `SNAPSHOT` arrives first and has already advanced
   * `lastEventId` past the entire batch. That was the replay bug.
   */
  applyEvents: (events: ServerEvent[]) => void;
  /** Registered by ws-client; invoked when a live event arrives out of sequence. */
  setResyncHandler: (handler: (() => void) | null) => void;
  addVoiceMember: (participantId: string) => void;
  removeVoiceMember: (participantId: string) => void;
  reset: () => void;
}

/** Not part of the store's reactive state — a plain module-level callback slot. */
let resyncHandler: (() => void) | null = null;

export const useSessionStore = create<SessionState>((set, get) => ({
  sessionId: null,
  participantId: null,
  token: null,
  joinCode: null,
  displayName: null,
  connected: false,
  sessionInvalid: false,
  lastEventId: 0,
  reconnectCount: 0,
  participants: new Map(),
  destination: null,
  chatMessages: [],
  hostParticipantId: null,
  isHost: false,
  voiceMembers: new Set(),
  activeSos: new Map(),

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

  setSessionInvalid: (v) => set({ sessionInvalid: v }),

  setHostParticipantId: (id) => {
    const state = get();
    set({
      hostParticipantId: id,
      isHost: state.participantId === id,
    });
  },

  incrementReconnectCount: () => set((s) => ({ reconnectCount: s.reconnectCount + 1 })),

  setResyncHandler: (handler) => {
    resyncHandler = handler;
  },

  applySnapshot: (snapshot) => {
    const participants = new Map<string, Participant>();
    for (const p of snapshot.participants) {
      participants.set(p.participantId, p);
    }

    const activeSos = new Map<string, ActiveSos>();
    for (const sos of snapshot.activeSos ?? []) {
      activeSos.set(sos.participantId, sos);
    }

    set({
      lastEventId: snapshot.latestEventId,
      destination: snapshot.destination,
      participants,
      activeSos,
    });
  },

  applyEvents: (events) => {
    // Ordered replay. `applyEventInternal` does the state transition; the
    // caller-facing dedup lives in `applyEvent` only.
    for (const event of events) {
      applyEventInternal(set, get, event);
    }
  },

  applyEvent: (event) => {
    const state = get();

    // Already applied — the live stream can legitimately redeliver during a
    // handshake overlap (a broadcast racing the snapshot).
    if (event.eventId <= state.lastEventId) return;

    // Gap: we missed at least one event. The snapshot/replay path is the only
    // thing that can fill it correctly, so force a resync rather than applying
    // out of order and silently losing the missing ids forever.
    if (state.lastEventId > 0 && event.eventId > state.lastEventId + 1) {
      if (resyncHandler) {
        resyncHandler();
        return;
      }
    }

    applyEventInternal(set, get, event);
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
      sessionInvalid: false,
      lastEventId: 0,
      reconnectCount: 0,
      participants: new Map(),
      destination: null,
      chatMessages: [],
      hostParticipantId: null,
      isHost: false,
      voiceMembers: new Set(),
      activeSos: new Map(),
    }),
}));

type SetState = (partial: Partial<SessionState>) => void;
type GetState = () => SessionState;

/**
 * The state transition for a single event. Shared by the live path
 * (`applyEvent`, which dedups first) and the replay path (`applyEvents`,
 * which does not). Always advances `lastEventId`.
 */
function applyEventInternal(set: SetState, get: GetState, event: ServerEvent): void {
  const state = get();
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
          battery: null,
          charging: null,
          arrived: false,
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
          battery: (data.battery as number | null) ?? p.battery ?? null,
          charging: (data.charging as boolean | null) ?? p.charging ?? null,
          status: 'online',
          lastSeenTs: event.ts,
        });
      }
      break;
    }
    case 'DESTINATION_SET': {
      // A new destination resets everyone's arrival state.
      for (const [pid, p] of participants) {
        if (p.arrived) participants.set(pid, { ...p, arrived: false });
      }
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
      for (const [pid, p] of participants) {
        if (p.arrived) participants.set(pid, { ...p, arrived: false });
      }
      set({ destination: null });
      break;
    }
    case 'CHAT_MESSAGE': {
      const chatMessages = [...state.chatMessages];
      // Replay can redeliver a message the client already holds locally.
      if (!chatMessages.some((m) => m.eventId === event.eventId)) {
        chatMessages.push({
          eventId: event.eventId,
          participantId: data.participantId as string,
          displayName: (data.displayName as string | null) ?? null,
          text: data.text as string,
          ts: event.ts,
        });
        chatMessages.sort((a, b) => a.eventId - b.eventId);
        // Keep last 200 messages in memory
        if (chatMessages.length > 200) {
          chatMessages.splice(0, chatMessages.length - 200);
        }
        set({ chatMessages });
      }
      break;
    }
    case 'SOS_RAISED': {
      const pid = data.participantId as string;
      const activeSos = new Map(state.activeSos);
      activeSos.set(pid, {
        participantId: pid,
        note: (data.note as string | null) ?? null,
        lat: (data.lat as number | null) ?? null,
        lng: (data.lng as number | null) ?? null,
        ts: (data.ts as number) ?? event.ts,
      });
      set({ activeSos });
      break;
    }
    case 'SOS_CLEARED': {
      const pid = data.participantId as string;
      const activeSos = new Map(state.activeSos);
      activeSos.delete(pid);
      set({ activeSos });
      break;
    }
    case 'ARRIVAL_PINGED': {
      const pid = data.participantId as string;
      const p = participants.get(pid);
      if (p) {
        participants.set(pid, { ...p, arrived: true });
      }
      break;
    }
  }

  set({ participants, lastEventId: event.eventId });
}
