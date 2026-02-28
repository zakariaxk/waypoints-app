// Voice chat service: join/leave voice channel, relay WebRTC signals.
// Uses the existing WS client to send VOICE_* messages.

import { sendJson, onMessage } from './ws-client';

export type VoiceState = 'joined' | 'left';

export interface VoiceStateEvent {
  participantId: string;
  state: VoiceState;
}

export interface VoiceSignalEvent {
  fromParticipantId: string;
  signalType: 'offer' | 'answer' | 'ice';
  data: Record<string, unknown>;
}

type VoiceStateHandler = (event: VoiceStateEvent) => void;
type VoiceSignalHandler = (event: VoiceSignalEvent) => void;

let voiceStateHandlers: VoiceStateHandler[] = [];
let voiceSignalHandlers: VoiceSignalHandler[] = [];
let unsubWs: (() => void) | null = null;

/** Start listening for VOICE_* messages from the WS client. */
export function initVoiceListeners(): () => void {
  if (unsubWs) return unsubWs; // already initialized

  unsubWs = onMessage((msg: unknown) => {
    const m = msg as { type?: string; payload?: Record<string, unknown> };
    if (!m.type || !m.payload) return;

    if (m.type === 'VOICE_STATE') {
      const event = m.payload as unknown as VoiceStateEvent;
      for (const handler of voiceStateHandlers) {
        handler(event);
      }
    } else if (m.type === 'VOICE_SIGNAL') {
      const event = m.payload as unknown as VoiceSignalEvent;
      for (const handler of voiceSignalHandlers) {
        handler(event);
      }
    }
  });

  return () => {
    if (unsubWs) {
      unsubWs();
      unsubWs = null;
    }
  };
}

/** Join the voice channel in the current session. */
export function joinVoice(): void {
  sendJson({ type: 'VOICE_JOIN', payload: {} });
}

/** Leave the voice channel in the current session. */
export function leaveVoice(): void {
  sendJson({ type: 'VOICE_LEAVE', payload: {} });
}

/** Send a WebRTC signal to a specific participant. */
export function sendSignal(
  toParticipantId: string,
  signalType: 'offer' | 'answer' | 'ice',
  data: Record<string, unknown>,
): void {
  sendJson({
    type: 'VOICE_SIGNAL',
    payload: { toParticipantId, signalType, data },
  });
}

/** Subscribe to VOICE_STATE events. Returns unsubscribe function. */
export function onVoiceState(handler: VoiceStateHandler): () => void {
  voiceStateHandlers.push(handler);
  return () => {
    voiceStateHandlers = voiceStateHandlers.filter((h) => h !== handler);
  };
}

/** Subscribe to VOICE_SIGNAL events. Returns unsubscribe function. */
export function onVoiceSignal(handler: VoiceSignalHandler): () => void {
  voiceSignalHandlers.push(handler);
  return () => {
    voiceSignalHandlers = voiceSignalHandlers.filter((h) => h !== handler);
  };
}
