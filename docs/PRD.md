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