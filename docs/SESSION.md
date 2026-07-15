# Fictional Practice Session

## Goal

Get Waypoints to a point where a session with 6 to 12 people feels instantaneous on mobile, reconnects without corrupting state, and can absorb auth, friends, and voice without forcing a protocol rewrite.

The non-negotiables going in:

- Real-time updates cannot depend on database round-trips.
- The mobile client has to survive app backgrounding and weak-network reconnects.
- State ownership has to stay obvious enough that a bug can be debugged from logs and a packet trace.
- The architecture should preserve one hard boundary: live session state versus persisted product state.

## Initial State

The app already had the right coarse shape:

- `POST /sessions` creates a session and returns a join code.
- `POST /sessions/join` validates the code and returns session identity plus an auth token.
- A WebSocket connection handles the actual live room.
- The React Native client uses HTTP for join/create and WS for everything time-sensitive.

What was missing was not feature surface. It was decision quality. Too many things were still “probably later”:

- whether the session source of truth lives in memory or in Postgres,
- whether location updates are events or just mutable live state,
- whether reconnect should rehydrate from snapshot, replay, or storage,
- whether voice belongs in the same replay model,
- and whether auth migration should change the handshake shape.

Those had to be resolved before adding more code.

## Session State Ownership

The first call was to make the backend authoritative for live state and keep that authority entirely in memory.

The state model settled into a single `SessionStore`:

- `sessions: Map<sessionId, SessionState>`

Each `SessionState` owns:

- `sessionId`
- `joinCode`
- `hostParticipantId`
- `participants: Map<participantId, ParticipantState>`
- `destination`
- `lastEventId`
- `eventBuffer`
- `voiceMembers`
- `persistQueue`

Each `ParticipantState` owns:

- `participantId`
- `userId` when authenticated
- `displayName`
- `lastLocation`
- `status`
- `lastSeenTs`
- `connId`
- `lastAcceptedLocationTs`

The alternative was to let Postgres or Supabase become the live truth for some subset of the room. That was rejected because it creates a split-brain product: one part of the app behaves like a real-time room and another behaves like a read-modify-write CRUD system.

That split would have shown up immediately in three places:

- location update latency,
- reconnect determinism,
- and stale presence transitions.

The decision was simple: the database is for continuity, analytics, and user graph. The WebSocket server is the room.

## Transport Contract

The WebSocket protocol stayed custom JSON over `ws` rather than switching to Socket.IO or a higher-level transport layer.

The reason was operational, not ideological. At this stage the team needs to debug by inspection. A bad room should be diagnosable from:

- the raw client payload,
- the server-side validation result,
- the state mutation,
- and the outbound broadcast.

That only works if the protocol remains explicit and small.

The core messages stayed close to this shape:

```json
{ "type": "HELLO", "sessionId": "...", "token": "...", "lastEventId": 42 }
{ "type": "LOC_UPDATE", "lat": 40.7128, "lng": -74.0060, "accuracy": 12, "heading": 180, "speed": 4.8, "ts": 1710000000000 }
{ "type": "SET_DESTINATION", "lat": 40.71, "lng": -74.00, "label": "Cafe" }
{ "type": "CLEAR_DESTINATION" }
{ "type": "VOICE_JOIN" }
{ "type": "VOICE_SIGNAL", "targetParticipantId": "...", "signal": { "sdp": "...", "type": "offer" } }
```

Server-originated messages fall into two distinct classes:

- session state messages like `WELCOME`, `SNAPSHOT`, `EVENT`, `ERROR`
- ephemeral relay messages for voice and transport coordination

That split became foundational.

## Reconnect Model

Reconnect was treated as the actual core feature. Voice, friends, and persistence were all secondary to this.

The client tracks `lastEventId` locally. On reconnect:

1. client sends `HELLO` with `sessionId`, token, and `lastEventId`
2. server authenticates and resolves `participantId`
3. server checks whether `lastEventId` can be satisfied by the ring buffer
4. server sends `WELCOME`
5. server sends `SNAPSHOT`
6. server optionally streams missing `EVENT`s if the gap is replayable

The buffer policy settled on:

- per-session monotonic `eventId`
- fixed-capacity ring buffer
- replay only if `clientLastEventId >= oldestBufferedEventId - 1`
- otherwise fall back to snapshot-only recovery

Two bad options were explicitly rejected:

- snapshot-only always, which loses causal continuity after reconnect
- durable replay from the database, which drags the hot path into storage and turns reconnect into a data fetch problem

The actual important property is not “perfect replay.” It is “correct recovery with bounded complexity.”

## What Counts As An Event

The protocol initially drifted toward event-sourcing everything. That was a mistake.

The correction was to ask of every message:

If this is replayed 30 seconds later to a freshly reconnected client, does it reconstruct meaningful application state or does it replay dead transport history?

That question divided the protocol cleanly.

Replayable session events:

- participant joined
- participant left
- destination set
- destination cleared
- display name changed
- explicit host-controlled room changes

Not replayable:

- raw GPS location updates
- WebRTC SDP offers/answers
- ICE candidates
- transient presence pings
- connection-bound voice membership chatter

The rule is that application state changes can be replayed. Connection topology cannot.

This mattered because otherwise the event buffer becomes a garbage stream of technically recorded but semantically stale information.

## Location Update Path

Location updates are the highest-frequency path in the system and therefore the place where architectural sloppiness becomes visible first.

The update path was tightened to:

1. inbound `LOC_UPDATE` validated with Zod at the WS boundary
2. participant resolved from the authenticated connection, never from client-provided IDs
3. server rejects updates arriving under `LOC_UPDATE_MIN_INTERVAL_MS` threshold
4. `lastLocation`, `lastSeenTs`, and `status` update in memory
5. outbound room fanout emits the latest accepted position
6. no database write occurs

The rate limiter remained intentionally primitive:

- timestamp-based minimum interval, default around 900ms to 1000ms

A token bucket would be more flexible but would solve a problem that does not exist yet. The primary abuse case is accidental over-send from the mobile app, not adversarial flooding by authenticated participants inside a small room.

The more important low-level call was to make the server authoritative on acceptance. The mobile client can emit GPS samples at whatever cadence the OS produces. The room only mutates on accepted updates.

That keeps room behavior stable when Android and iOS behave differently under background throttling.

## Presence Semantics

Presence could not be a direct mirror of socket connectivity because mobile networks are too noisy.

The final model remained three-state:

- `online`
- `stale`
- `offline`

But the implementation detail that mattered was this:

- `online` is a derived state from recent accepted updates plus active connection
- `stale` is a timeout-based degradation of confidence
- `offline` is either explicit disconnect or prolonged inactivity beyond the stale window

This means the backend periodically evaluates participants rather than just flipping presence on connect/disconnect callbacks.

That tiny distinction prevents a common bad UX: someone disappears from the room because a socket bounced for a second even though they are still effectively present.

## Destination Ownership

The room originally tolerated multiple participants mutating destination state. That created too much ambiguity for both product and code.

The fix was to bind destination control to `hostParticipantId`.

Enforcement happens server-side:

- `SET_DESTINATION` and `CLEAR_DESTINATION` check `participantId === hostParticipantId`
- unauthorized attempts return `ERROR` with a `FORBIDDEN` code
- successful updates increment `lastEventId` and enter the replay buffer

Two technical benefits fell out of a product rule:

- room state stopped oscillating under contention
- destination became a stable replayable event instead of a contested mutable field

That also simplified the React Native session screen because the UI could hide or disable destination actions for non-hosts rather than guessing whether a command would succeed.

## Input Validation Boundary

Validation was pushed fully to the edge instead of being spread through handlers.

That meant:

- HTTP request bodies validated before session mutation
- join code format enforced up front
- display names trimmed and truncated before storage
- WS messages parsed as discriminated unions
- impossible message shapes rejected before touching `SessionState`

This was one of the most important low-level decisions because it changes the failure mode of the whole service.

Without edge validation, invalid payloads create defensive code everywhere:

- null-checks in room logic
- partial state in participants maps
- inconsistent event payloads
- UI branches for states that should never exist

With validation at the boundary, the internal state model stays narrow and handlers become mostly straight-line logic.

## JWT Migration Without Handshake Breakage

Auth had to move from random participant tokens to Supabase JWTs without forcing a flag day across mobile clients.

The handshake kept the same outer shape:

```json
{ "type": "HELLO", "sessionId": "...", "token": "...", "participantId": "optional-legacy", "lastEventId": 42 }
```

The meaning of `token` changed.

Migration logic:

- if `token` verifies against `SUPABASE_JWT_SECRET`, treat it as authenticated identity
- resolve `userId` from JWT claims
- map `userId + sessionId` to the participant row
- ignore client authority over participant identity

Legacy fallback:

- if token is not a valid JWT, attempt old random-token lookup
- require `participantId`
- mark path for removal after client rollout completes

This is not glamorous work, but it is the kind of detail that determines whether a migration is annoying or catastrophic.

The critical idea was to preserve packet shape while changing trust semantics under the hood.

## Persistence Boundary

Once auth and durable product data were introduced, the system drew a hard line between what gets written to Supabase and what never should.

Persisted:

- user profiles
- friend relationships
- session metadata
- meaningful room history
- auth state and user linkage

Not persisted:

- per-second location stream
- transient presence transitions
- voice signaling payloads
- ephemeral connection IDs
- replay ring buffer contents

The event history policy became explicit:

- store only events with human-readable or product-meaningful history value
- batch them asynchronously
- drop batches on failure instead of blocking the room

The async flusher was conceptually:

- append eligible events to an in-memory per-session queue
- flush every 5 seconds or when queue reaches threshold
- insert batched rows
- on failure log and drop the batch
- cap queue size so persistence failure cannot become a memory leak

That decision only works because the authoritative layer is already in memory. If persisted history were treated as critical truth, dropping batches would be unacceptable. Since it is derivative history, bounded loss is preferable to live-session latency.

## Voice Integration

Voice was deliberately kept outside the replay model even though it shares the WebSocket transport.

The voice path settled into:

- `VOICE_JOIN`
- `VOICE_LEAVE`
- `VOICE_SIGNAL`
- `VOICE_STATE`

Server behavior:

- track current voice membership by live connection only
- relay signaling packets to the intended participant
- clear voice membership on disconnect and `LEAVE_SESSION`
- do not assign `eventId`
- do not emit as replay `EVENT`
- do not store in the ring buffer

The reason is structural, not just performance-related.

SDP offers, answers, and ICE candidates are only meaningful relative to a specific peer connection graph. Replaying them after reconnect would not restore voice. It would inject stale signaling into a dead graph.

The reconnect rule for voice is therefore explicit:

- client finishes room rejoin first
- then sends `VOICE_JOIN`
- then renegotiates peer connections from scratch

That keeps the room replay model clean and prevents a whole class of phantom voice bugs.

## Cleanup And TTL

Single-instance in-memory state needs disciplined cleanup or it silently turns into a memory retention bug.

The session cleanup policy stayed intentionally boring:

- periodic sweep every 60 seconds
- drop empty sessions older than TTL
- clear connection mappings on disconnect
- clear voice membership on leave/disconnect
- evict event buffer naturally by ring capacity

The important part was not the exact TTL. It was refusing to let “we only have one instance” become an excuse for unlimited in-memory residue.

## Mobile Client Constraints

The React Native client had to align with the server’s truth model instead of inventing its own.

Client behavior settled around:

- HTTP create/join for bootstrapping
- persist `sessionId`, auth token, and `lastEventId`
- reconnect WS automatically with the last seen event marker
- treat `SNAPSHOT` as authoritative base state
- apply replayed `EVENT`s in order
- submit GPS samples through a location service, but accept that the server may drop over-frequent updates

The key low-level client rule was to avoid optimistic mutation of room state that the server actually owns.

Examples:

- destination changes are not locally committed until server confirmation path returns through room state
- presence is rendered from server-derived state, not from local socket assumptions
- reconnect uses the server’s snapshot as reset truth, not locally cached participant maps

This reduces client cleverness, which is usually good in a real-time mobile system.

## Failure Cases Intentionally Accepted

The session intentionally accepted several imperfect behaviors because fixing them early would add more complexity than value:

- if the event gap exceeds ring capacity, reconnect falls back to snapshot instead of fetching old history
- if Supabase is down, session history may be lost while the room continues functioning
- if a client reconnects during voice activity, voice renegotiation restarts instead of trying to resume transport state
- if mobile GPS emits faster than allowed, extra updates are dropped server-side rather than queued

These are not oversights. They are chosen failure boundaries.

The system is better when its degradations are explicit and narrow instead of pretending to be comprehensive while failing in opaque ways.

## Result

By the end of the session, the architecture had a coherent center:

- one authoritative live room per `sessionId`
- monotonic replayable events for durable-enough state changes
- mutable in-memory participant state for high-frequency location and presence
- bounded replay with snapshot fallback
- host-controlled destination updates
- dual-mode auth migration path
- asynchronous best-effort history persistence
- voice signaling treated as purely ephemeral transport state

The most important outcome was not a feature. It was that every subsystem now answers the same question consistently:

Is this live room state, replayable session history, or transient connection data?

Once that line was clear, the rest of Waypoints stopped feeling like a pile of features and started behaving like a system.
