// useVoiceChat — WebRTC voice chat hook for Waypoints sessions.
// Manages peer connections, microphone capture, mute, and push-to-talk.
//
// Requires react-native-webrtc (native module, needs EAS dev client).
// See docs/MANUAL_ACTIONS.md for setup steps.
//
// IMPORTANT: react-native-webrtc is lazy-loaded so the app doesn't crash
// in Expo Go (which lacks the native module). The import only happens when
// the user actually taps "Join Voice".

import { useEffect, useRef, useState, useCallback } from 'react';
import { useSessionStore } from '../state/session-store';
import {
  joinVoice,
  leaveVoice,
  sendSignal,
  onVoiceState,
  onVoiceSignal,
  initVoiceListeners,
  type VoiceSignalEvent,
  type VoiceStateEvent,
} from '../services/voice';
import { Platform, PermissionsAndroid, Alert } from 'react-native';

// STUN servers (free, public)
const ICE_SERVERS = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
];

// Lazy-loaded WebRTC module — only resolved when first needed.
// react-native-webrtc is a native module that crashes Expo Go on require().
// We gate on NativeModules first; the actual require() is behind a safe check.
let _webrtc: any = null;
let _webrtcChecked = false;

function getWebRTC(): any {
  if (_webrtcChecked) return _webrtc;
  _webrtcChecked = true;
  try {
    // Check if the native module exists before requiring the JS wrapper.
    // In Expo Go the native module is absent — bail out early.
    // A runtime require, not a static import: importing react-native-webrtc at
    // module scope crashes in Expo Go, where the native module is absent.
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const { NativeModules } = require('react-native');
    if (!NativeModules.WebRTCModule) {
      return null;
    }
    _webrtc = require('react-native-webrtc');
    return _webrtc;
  } catch {
    return null;
  }
}

interface PeerState {
  pc: any; // RTCPeerConnection — typed as any since we lazy-load
  participantId: string;
}

export interface VoiceChatState {
  joined: boolean;
  muted: boolean;
  pushToTalkEnabled: boolean;
  remoteParticipants: string[];
  peerCount: number;
  connecting: boolean;
}

export function useVoiceChat(sessionId: string | null) {
  const [joined, setJoined] = useState(false);
  const [muted, setMuted] = useState(true); // start muted
  const [pushToTalkEnabled, setPushToTalkEnabled] = useState(false);
  const [connecting, setConnecting] = useState(false);
  const [remoteParticipants, setRemoteParticipants] = useState<string[]>([]);

  const localStreamRef = useRef<any>(null); // MediaStream — typed as any for lazy-load
  const peersRef = useRef<Map<string, PeerState>>(new Map());
  const joinedRef = useRef(false);
  const mutedRef = useRef(true);
  const participantId = useSessionStore((s) => s.participantId);

  // Keep refs in sync
  useEffect(() => {
    joinedRef.current = joined;
  }, [joined]);
  useEffect(() => {
    mutedRef.current = muted;
  }, [muted]);

  // Request microphone permission (platform-correct)
  const requestMicPermission = useCallback(async (): Promise<boolean> => {
    if (Platform.OS === 'android') {
      const granted = await PermissionsAndroid.request(
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
        {
          title: 'Microphone Permission',
          message: 'Waypoints needs microphone access for voice chat.',
          buttonPositive: 'Allow',
          buttonNegative: 'Deny',
        },
      );
      return granted === PermissionsAndroid.RESULTS.GRANTED;
    }
    // iOS: permission requested automatically when accessing media
    return true;
  }, []);

  // Get local audio stream
  const getLocalStream = useCallback(async (): Promise<any | null> => {
    try {
      const webrtc = getWebRTC();
      if (!webrtc) return null;
      const stream = await webrtc.mediaDevices.getUserMedia({
        audio: true,
        video: false,
      });
      return stream;
    } catch (err) {
      console.warn('[Voice] Failed to get local audio stream:', err);
      return null;
    }
  }, []);

  // Create a peer connection to a remote participant
  const createPeerConnection = useCallback(
    (remoteParticipantId: string, isInitiator: boolean) => {
      if (!_webrtc) {
        console.warn('[Voice] WebRTC module not loaded');
        return null;
      }
      const pc: any = new _webrtc.RTCPeerConnection({ iceServers: ICE_SERVERS });

      // Add local audio tracks
      if (localStreamRef.current) {
        for (const track of localStreamRef.current.getTracks()) {
          pc.addTrack(track, localStreamRef.current);
        }
      }

      // ICE candidate handling
      pc.addEventListener('icecandidate', (event: any) => {
        if (event.candidate) {
          sendSignal(remoteParticipantId, 'ice', {
            candidate: event.candidate.candidate,
            sdpMid: event.candidate.sdpMid,
            sdpMLineIndex: event.candidate.sdpMLineIndex,
          });
        }
      });

      // Track remote streams (for audio playback — handled by RN WebRTC automatically)
      pc.addEventListener('track', (_event: any) => {
        // Remote audio tracks are played automatically by react-native-webrtc
        setRemoteParticipants((prev) => {
          if (prev.indexOf(remoteParticipantId) === -1) {
            return [...prev, remoteParticipantId];
          }
          return prev;
        });
      });

      pc.addEventListener('connectionstatechange', () => {
        if (
          pc.connectionState === 'disconnected' ||
          pc.connectionState === 'failed' ||
          pc.connectionState === 'closed'
        ) {
          cleanupPeer(remoteParticipantId);
        }
      });

      const peerState: PeerState = { pc, participantId: remoteParticipantId };
      peersRef.current.set(remoteParticipantId, peerState);

      // If initiator, create and send offer
      if (isInitiator) {
        (async () => {
          try {
            const offer = await pc.createOffer({});
            await pc.setLocalDescription(offer);
            sendSignal(remoteParticipantId, 'offer', {
              type: offer.type,
              sdp: offer.sdp,
            });
          } catch (err) {
            console.warn('[Voice] Error creating offer:', err);
          }
        })();
      }

      return pc;
    },
    [],
  );

  // Cleanup a single peer
  const cleanupPeer = useCallback((remoteParticipantId: string) => {
    const peer = peersRef.current.get(remoteParticipantId);
    if (peer) {
      peer.pc.close();
      peersRef.current.delete(remoteParticipantId);
      setRemoteParticipants((prev) => prev.filter((id) => id !== remoteParticipantId));
    }
  }, []);

  // Cleanup all peers and local stream
  const cleanupAll = useCallback(() => {
    for (const [, peer] of peersRef.current) {
      peer.pc.close();
    }
    peersRef.current.clear();
    setRemoteParticipants([]);

    if (localStreamRef.current) {
      for (const track of localStreamRef.current.getTracks()) {
        track.stop();
      }
      localStreamRef.current = null;
    }
  }, []);

  // Handle incoming voice signals
  const handleVoiceSignal = useCallback(
    async (event: VoiceSignalEvent) => {
      if (!joinedRef.current) return;

      const { fromParticipantId, signalType, data } = event;

      if (signalType === 'offer') {
        // Create peer connection if needed (we're the answerer)
        let peer = peersRef.current.get(fromParticipantId);
        if (!peer) {
          createPeerConnection(fromParticipantId, false);
          peer = peersRef.current.get(fromParticipantId);
        }
        if (!peer) return;

        try {
          const RSD = _webrtc?.RTCSessionDescription;
          if (!RSD) return;
          await peer.pc.setRemoteDescription(
            new RSD({ type: data.type as string, sdp: data.sdp as string }),
          );
          const answer = await peer.pc.createAnswer();
          await peer.pc.setLocalDescription(answer);
          sendSignal(fromParticipantId, 'answer', {
            type: answer.type,
            sdp: answer.sdp,
          });
        } catch (err) {
          console.warn('[Voice] Error handling offer:', err);
        }
      } else if (signalType === 'answer') {
        const peer = peersRef.current.get(fromParticipantId);
        if (!peer) return;

        try {
          const RSD2 = _webrtc?.RTCSessionDescription;
          if (!RSD2) return;
          await peer.pc.setRemoteDescription(
            new RSD2({ type: data.type as string, sdp: data.sdp as string }),
          );
        } catch (err) {
          console.warn('[Voice] Error handling answer:', err);
        }
      } else if (signalType === 'ice') {
        const peer = peersRef.current.get(fromParticipantId);
        if (!peer) return;

        try {
          const RIC = _webrtc?.RTCIceCandidate;
          if (!RIC) return;
          await peer.pc.addIceCandidate(
            new RIC({
              candidate: data.candidate as string,
              sdpMid: data.sdpMid as string,
              sdpMLineIndex: data.sdpMLineIndex as number,
            }),
          );
        } catch (err) {
          console.warn('[Voice] Error handling ICE candidate:', err);
        }
      }
    },
    [createPeerConnection],
  );

  // Handle voice state changes (participants joining/leaving voice)
  const handleVoiceState = useCallback(
    (event: VoiceStateEvent) => {
      if (!joinedRef.current) return;
      if (event.participantId === participantId) return; // ignore self

      if (event.state === 'joined') {
        // New participant joined voice — we initiate the connection if we have a "higher" id
        // (simple deterministic tie-breaking to avoid duplicate offers)
        if (participantId && participantId > event.participantId) {
          if (!peersRef.current.has(event.participantId)) {
            createPeerConnection(event.participantId, true);
          }
        }
      } else if (event.state === 'left') {
        cleanupPeer(event.participantId);
      }
    },
    [participantId, createPeerConnection, cleanupPeer],
  );

  // Initialize voice listeners
  useEffect(() => {
    const cleanupListeners = initVoiceListeners();
    const unsubState = onVoiceState(handleVoiceState);
    const unsubSignal = onVoiceSignal(handleVoiceSignal);

    return () => {
      cleanupListeners();
      unsubState();
      unsubSignal();
    };
  }, [handleVoiceState, handleVoiceSignal]);

  // Apply mute state to local audio track
  useEffect(() => {
    if (localStreamRef.current) {
      const audioTracks = localStreamRef.current.getAudioTracks();
      for (const track of audioTracks) {
        (track as any).enabled = !muted;
      }
    }
  }, [muted]);

  // Join voice channel
  const join = useCallback(async () => {
    if (joined || !sessionId) return;

    setConnecting(true);

    // Check WebRTC native module availability (fails in Expo Go)
    const webrtc = getWebRTC();
    if (!webrtc) {
      Alert.alert(
        'Dev Client Required',
        'Voice chat requires native modules that aren\'t available in Expo Go. ' +
        'Build an EAS development client to use voice chat.\n\nSee docs/MANUAL_ACTIONS.md.',
      );
      setConnecting(false);
      return;
    }

    const hasPermission = await requestMicPermission();
    if (!hasPermission) {
      setConnecting(false);
      return;
    }

    const stream = await getLocalStream();
    if (!stream) {
      setConnecting(false);
      return;
    }

    localStreamRef.current = stream;

    // Start muted
    const audioTracks = stream.getAudioTracks();
    for (const track of audioTracks) {
      (track as any).enabled = false;
    }

    setJoined(true);
    setMuted(true);
    joinVoice();

    // Connect to existing voice members (after a small delay for VOICE_STATE to propagate)
    setTimeout(() => {
      const currentVoiceMembers = useSessionStore.getState().voiceMembers;
      for (const memberId of currentVoiceMembers) {
        if (memberId !== participantId && !peersRef.current.has(memberId)) {
          // Use tie-breaking: higher ID initiates
          if (participantId && participantId > memberId) {
            createPeerConnection(memberId, true);
          }
        }
      }
      setConnecting(false);
    }, 300);
  }, [joined, sessionId, participantId, requestMicPermission, getLocalStream, createPeerConnection]);

  // Leave voice channel
  const leave = useCallback(() => {
    if (!joined) return;

    leaveVoice();
    cleanupAll();
    setJoined(false);
    setMuted(true);
    setPushToTalkEnabled(false);
  }, [joined, cleanupAll]);

  // Toggle mute
  const toggleMute = useCallback(() => {
    setMuted((prev) => !prev);
  }, []);

  // Toggle push-to-talk mode
  const togglePushToTalk = useCallback(() => {
    setPushToTalkEnabled((prev) => !prev);
  }, []);

  // Push-to-talk: press to unmute
  const pttPress = useCallback(() => {
    if (pushToTalkEnabled && joined) {
      setMuted(false);
    }
  }, [pushToTalkEnabled, joined]);

  // Push-to-talk: release to mute
  const pttRelease = useCallback(() => {
    if (pushToTalkEnabled && joined) {
      setMuted(true);
    }
  }, [pushToTalkEnabled, joined]);

  // Cleanup on unmount or session change
  useEffect(() => {
    return () => {
      if (joinedRef.current) {
        leaveVoice();
      }
      cleanupAll();
    };
  }, [sessionId, cleanupAll]);

  return {
    // State
    available: getWebRTC() !== null,
    joined,
    muted,
    pushToTalkEnabled,
    connecting,
    remoteParticipants,
    peerCount: remoteParticipants.length,

    // Actions
    join,
    leave,
    toggleMute,
    togglePushToTalk,
    pttPress,
    pttRelease,
  };
}
