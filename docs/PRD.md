# Waypoints – Product Requirements (MVP)

## One-liner
Waypoints is a real-time social location sharing app for "sessions" where friends can see each other on a live map, with reconnect-safe synchronization.

## Inspiration (not a clone)
Inspired by apps like convoy-style live location sharing. We are building our own branding, UX, and naming.

## MVP Goals
- Create and join a session via code/link
- Live map showing participant locations
- Presence list (online / stale / offline)
- Reconnect-safe real-time sync (no weird jumps, duplicates, or missing updates)
- Destination marker (host sets a destination; everyone sees it)
- Optional: basic session chat (phase 1.5)

## Non-goals (MVP)
- Voice calls / proximity chat
- Background location (Always-on)
- Multi-stop route editing
- Payments, subscriptions
- Public feed / social network features

## Key Concepts
- Session: a temporary group event users join to share location
- Participant: user inside a session
- Presence state: online/offline/stale based on last update time
- Events: ordered messages used to guarantee reconnect correctness

## User Stories
1) As a user, I can create a session and share an invite code.
2) As a user, I can join a session and immediately see everyone on the map.
3) As a user, I can see who is active and when someone’s location last updated.
4) As a user, if I lose network, I can reconnect and resync without losing correctness.
5) As a host, I can set/change a destination and everyone sees it.

## Acceptance Criteria (MVP)
- A user can create a session and receive a join code.
- A user can join the session with the code.
- Live updates: participant markers update on map in near real time.
- Presence: if a participant hasn’t updated in N seconds, they show as stale; if disconnected, offline.
- Reconnect: after disconnect, client reconnects and receives all missed events since lastEventId.
- Server must reject malformed WS messages with an ERROR response.
- App must not crash when location permission is denied; show a clear message.

## Performance Targets (MVP)
- Location update frequency: 1 update/sec per client (configurable).
- Supports at least 20 concurrent users in one session for testing.

## Data Retention (MVP)
- Only keep last known location in memory during the session.
- No long-term location history storage in MVP.

## Privacy
- Location is shared only within a session the user joins.
- No public browsing of users/sessions.

## Visual Identity — Cyberpunk / Neon-Tech UI

### Aesthetic
Dark-first, neon-lit HUD with translucent panels, colored glow effects, and cinematic gradients. Inspired by cyberpunk aesthetics — futuristic but highly readable.

### Key Design Decisions
- **Color palette**: Deep-space blacks (#05060A, #0A0C14), neon accents (cyan #2DE2E6, magenta #FF2A6D, violet #7A5CFF, lime #B6FF6A, amber #FFB000).
- **Typography**: Orbitron (headings) + Rajdhani (body) — geometric/futuristic font pairing.
- **Panels**: Translucent `rgba(20,24,40,0.72)` with subtle neon borders rather than opaque cards.
- **Glow system**: Colored shadows on iOS, elevation on Android for neon glow effects.
- **Haptics**: All interactive buttons provide tactile feedback.
- **Participant colors**: 8-color neon rotating palette for individual markers and avatars.
- **Light mode**: Supported but secondary — light backgrounds with deeper neon tones for contrast.

### Full Style Reference
See [docs/UI_STYLEGUIDE.md](./UI_STYLEGUIDE.md) for the complete token reference, component catalog, and design principles.

---

## Phase 2: Voice Chat

### Overview
Real-time voice communication between session participants using WebRTC peer-to-peer audio, with signaling relayed through the existing WebSocket server. This is a post-MVP feature that extends the session experience without changing any MVP behavior.

### Goals
- Enable participants in a session to join an optional voice channel
- WebRTC peer-to-peer audio streaming (no server-side media processing)
- Minimal UI: join/leave voice, mute toggle, push-to-talk (PTT)
- Free-tier friendly: single backend instance, in-memory only, no TURN server (STUN only for MVP)
- Ephemeral: voice state is not persisted, not replayed on reconnect

### Non-Goals (Phase 2)
- Video chat
- Voice recording or persistence
- Server-side audio mixing or relaying (SFU/MCU)
- TURN server (relies on STUN; may be added later if NAT traversal issues arise)
- Noise cancellation or audio processing beyond platform defaults

### User Stories
1. As a participant, I can join/leave an optional voice channel within my session.
2. As a participant, I can mute/unmute my microphone.
3. As a participant, I can use push-to-talk (press and hold to speak).
4. As a participant, I can see how many people are in the voice channel and their connection state.
5. As a participant, if I disconnect and reconnect, I can re-join voice manually (voice is not auto-restored).

### Technical Approach
- **Signaling**: WebRTC offer/answer/ICE relayed via existing WS server using VOICE_SIGNAL messages.
- **Voice membership**: Tracked in-memory via `voiceMembers: Set<participantId>` per session.
- **Ephemeral**: VOICE_* messages are NOT part of the EVENT stream, NOT replayed on reconnect.
- **Mesh topology**: Each participant creates a direct peer connection to every other voice participant (suitable for small groups ≤ 8).
- **Protocol**: See [docs/WS-PROTOCOL.md](./WS-PROTOCOL.md) for VOICE_* message definitions.

### Implementation Phases
- **Phase A0**: Signaling + voice presence (server-side VOICE_JOIN/LEAVE/SIGNAL handlers, mobile ws-client integration, UI stub)
- **Phase A1**: Mobile WebRTC audio integration (react-native-webrtc, microphone capture, peer connection management, full voice UI)