# Waypoints — Phase 3 Spec: Spatial Voice + Live Safety

**Status:** Draft (proposed) · **Depends on:** Phase 2 Voice Chat (Batch 18) · **Owner:** TBD

## 1. One-liner

Make the session feel *present and safe*: voice that fades with map distance (spatial audio),
and a lightweight safety layer — SOS, "I've arrived" pings, and low-battery warnings — so a group
moving together always knows who's okay and where the trouble is.

## 2. Why now

Phase 2 shipped ephemeral mesh voice (≤8 peers, STUN-only). Presence, ETA, arrival detection, and
per-user routes already exist (Batch 16). Phase 3 stitches those two halves together:

- **Spatial audio** reuses the location stream the app already broadcasts (`LOCATION_UPDATED`) and the
  peer connections voice already maintains. No new transport, no server media work.
- **Safety signals** reuse the ordered event stream and presence model. They are the first features
  where *missing* a message matters, so they ride the replayable `EVENT` path — unlike voice.

Both stay inside every hard constraint: in-memory, single instance, no DB, no auth provider, no paid
infra. STUN-only remains; spatial audio is a client-side gain computation.

## 3. Goals

1. **Spatial voice** — each peer's incoming audio volume scales with the Haversine distance between
   the two participants on the map. Close = full volume, far = quiet/muted. Purely client-side gain on
   the existing WebRTC audio; no protocol change to voice signaling.
2. **SOS / panic** — any participant can raise an SOS. It broadcasts as a durable, replayable event,
   pins the sender's location, and alerts every other participant (haptics + visual + optional voice
   duck). Sender can clear it.
3. **Arrival ping** — a participant can announce "I've arrived" (or the client auto-fires it when
   arrival is detected within 50m of destination). Durable event, shown in presence + summary.
4. **Battery broadcast** — clients periodically include battery level + charging state; low battery
   (<15%, not charging) surfaces a warning badge on that participant so the group knows they may drop.
5. **Safety-aware presence** — presence list and map convey these states without extra taps.

## 4. Non-goals (Phase 3)

- No server-side audio mixing / SFU. Spatial gain is computed per-client.
- No TURN server. STUN-only carries over from Phase 2.
- No background location or always-on tracking (still a hard non-goal — battery + arrival only fire
  while the session screen is active).
- No emergency-services integration (no 911 dialing, no SMS to contacts). "SOS" is *in-session* only.
- No persistence of safety events beyond session lifetime / ring buffer.
- No accounts, no DB, no new paid infra.

## 5. Design

### 5.1 Spatial voice (client-only)

The client already receives every participant's location via `LOCATION_UPDATED` and holds a
`RTCPeerConnection` per voice peer. Add a gain stage:

- Wrap each remote audio track in a Web Audio-style gain node (via `react-native-webrtc`'s audio
  routing, or a per-peer output volume if the library exposes it — see Open Questions §9).
- On each location update for self or a peer, recompute distance `d` (existing Haversine helper) and
  set that peer's gain via a falloff curve:

  ```
  gain = clamp( (FALLOFF_MAX_M - d) / (FALLOFF_MAX_M - FALLOFF_MIN_M), 0, 1 )
  ```

  - `FALLOFF_MIN_M` (full volume within, default 50m) and `FALLOFF_MAX_M` (silent beyond, default
    500m) are client constants, tunable in settings later.
- A **"proximity voice" toggle** (default on) lets a user fall back to flat full-volume voice.
- Gain updates are debounced to location cadence (~1/sec); no audio glitching on rapid recompute
  (ramp gain over ~150ms).

No server change. Spatial audio is invisible to the protocol — it only reads data already flowing.

### 5.2 SOS / panic (durable event)

New host-agnostic action — **any** participant may send it.

- **Client → Server:** `RAISE_SOS { note?: string (≤140 chars) }`, `CLEAR_SOS {}`.
- Server assigns an `eventId`, stamps `ts`, records `sosActive: Set<participantId>` (or a
  `Map<participantId, { note, ts }>`) on `SessionState`, and broadcasts:
  - `SOS_RAISED { participantId, note, lat, lng, ts }` — lat/lng taken from the sender's last known
    location on the server (do not trust a client-supplied position).
  - `SOS_CLEARED { participantId }`.
- Because SOS is safety-critical, it **is** a replayable `EVENT` (unlike voice): a participant who
  reconnects must learn an SOS is still active. Active SOS state is included in `SNAPSHOT`.
- Client reaction: strong haptic, full-screen-safe banner, sender's marker pulses red and is
  force-focused; optionally ducks spatial voice gain so the SOS sender is audible regardless of
  distance.

### 5.3 Arrival ping (durable event)

- **Client → Server:** `ARRIVAL_PING {}` (manual "I'm here" button) — server validates the sender is
  within `ARRIVAL_RADIUS_M` (default 50m) of the destination, else `FORBIDDEN`/`BAD_MESSAGE`.
- Client also auto-fires once when local arrival detection crosses 50m (existing Batch 16 logic),
  guarded so it sends at most once per destination.
- Server broadcasts `ARRIVAL_PINGED { participantId, ts }`, marks arrival in session state, includes
  arrived set in `SNAPSHOT`, and it flows into the existing Session Summary (arrival order).

### 5.4 Battery broadcast (presence enrichment, not an event)

Battery is high-frequency and low-value-on-replay — like location, it enriches presence rather than
the durable event stream.

- Extend `LOC_UPDATE` payload with optional `battery: number (0..1) | null` and
  `charging: boolean | null` (mobile reads via `expo-battery`).
- Server stores latest battery on `ParticipantState`, includes it in `SNAPSHOT` participant rows and
  in `LOCATION_UPDATED` event data.
- Client derives a **low-battery badge** when `battery < 0.15 && !charging`. No separate message type;
  no new event kind. (Chosen over a dedicated `BATTERY_LOW` event to avoid event-stream noise —
  documented in DECISIONS.)

### 5.5 Presence / UI surface

- Presence list rows gain: 🔋 low-battery badge, 🆘 SOS chip, ✓ arrived chip (arrived already exists).
- Map: SOS marker pulses red + camera snaps; low battery dims/annotates the marker.
- Voice UI: proximity toggle, and a small "N nearby / M far" indicator when spatial voice is on.

## 6. Protocol changes (update `docs/WS-PROTOCOL.md` + `packages/shared` in the same change)

### New client → server messages
| Type | Payload | Rules |
|---|---|---|
| `RAISE_SOS` | `{ note?: string ≤140 }` | Any participant. Server sources location. |
| `CLEAR_SOS` | `{}` | Only clears sender's own SOS. |
| `ARRIVAL_PING` | `{}` | Server validates ≤ `ARRIVAL_RADIUS_M` from destination. |

### Changed client → server message
| Type | Change |
|---|---|
| `LOC_UPDATE` | Add optional `battery: number\|null`, `charging: boolean\|null`. |

### New event kinds (durable, replayable, in `SNAPSHOT`)
| Kind | `data` |
|---|---|
| `SOS_RAISED` | `{ participantId, note, lat, lng, ts }` |
| `SOS_CLEARED` | `{ participantId }` |
| `ARRIVAL_PINGED` | `{ participantId, ts }` |

### Changed event / snapshot shapes
- `LOCATION_UPDATED.data` gains `battery`, `charging`.
- `SNAPSHOT.participants[]` rows gain `battery`, `charging`, `arrived: boolean`, `sos: { note, ts } | null`.
- `SNAPSHOT` gains an `activeSos: [{ participantId, note, lat, lng, ts }]` array (or fold into rows).

### New error codes
- `NOT_ARRIVED` — `ARRIVAL_PING` sent from outside arrival radius (or reuse `BAD_MESSAGE`; decide).

All new inbound messages validated with Zod in `packages/shared/validators.ts`; invalid → `ERROR`.

## 7. State model additions (in-memory, per session)

```
SessionState += {
  sosActive: Map<participantId, { note: string; ts: number }>   // durable in snapshot
  arrived:   Set<participantId>                                  // durable in snapshot
}
ParticipantState += {
  battery:  number | null    // 0..1, latest
  charging: boolean | null
}
```

No new storage layer. All lives in the existing `Map<sessionId, SessionState>`; cleared on session
TTL cleanup like everything else.

## 8. Implementation phases (batches)

- **Batch 19 — Safety events (backend-first, tests gate).**
  Shared types + Zod for `RAISE_SOS`/`CLEAR_SOS`/`ARRIVAL_PING`, `LOC_UPDATE` battery fields, new
  event kinds. Backend handlers, state additions, snapshot inclusion, replay coverage. Update
  WS-PROTOCOL, DECISIONS (battery-not-an-event, SOS-is-replayable), ARCHITECTURE. **New vitest cases:**
  SOS raise/clear broadcast + snapshot + replay; arrival radius validation; battery in snapshot;
  SOS survives reconnect; non-sender can't clear another's SOS.
- **Batch 20 — Mobile safety UI.**
  `expo-battery` dep (document justification), SOS button + banner + haptics, arrival ping button +
  auto-fire guard, low-battery badge, presence/map surfacing, snapshot/replay handling in ws-client
  + Zustand store.
- **Batch 21 — Spatial voice (client-only).**
  Per-peer gain in `useVoiceChat.ts`, falloff constants, proximity toggle, SOS voice-duck, nearby/far
  indicator. No backend or protocol change. Verify on device (spatial audio can't be unit-tested at
  the mesh layer).

## 9. Open questions

1. Does the pinned `react-native-webrtc` expose per-remote-track output gain on both iOS and Android?
   If not, spatial voice may need a small native shim — that would touch the "no new native module"
   comfort zone (still free, but document it). **Blocker for Batch 21 — verify first.**
2. SOS while a participant has no known location yet (joined, no `LOC_UPDATE`) — broadcast with
   `lat/lng: null` and skip camera-snap, or reject? Proposed: allow, null location, no snap.
3. `expo-battery` background behavior — confirm it only reads while foregrounded (aligns with the
   no-background-location non-goal).
4. Should SOS auto-clear on the sender's disconnect, or persist (they may have lost signal *because*
   of the emergency)? Proposed: **persist** — keep SOS active on disconnect; only `CLEAR_SOS` or
   session end removes it. Presence still shows them offline.

## 10. Constraints check

| Constraint | Respected? |
|---|---|
| In-memory only | ✅ new state is Maps/Sets on `SessionState` |
| Single instance | ✅ no cross-instance needs |
| No auth provider | ✅ participant token model unchanged |
| No paid infra | ✅ STUN-only, no TURN, no media server |
| No new dep without justification | `expo-battery` (Batch 20) — document in ARCHITECTURE + this spec |
| Free-tier friendly | ✅ |
| Voice stays ephemeral | ✅ spatial voice adds no protocol; safety events are a *separate*, deliberately-replayable path |
```
