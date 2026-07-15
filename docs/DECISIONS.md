# Decisions

- WebSockets: ws (custom JSON protocol)
- MVP: single backend instance, in-memory state
- Update rate: 1/sec per client
- No Redis until scaling

## 2026-02-28 — Voice events are ephemeral and not replayed

**Context**: Adding Phase 2 Voice Chat with WebRTC signaling relayed through the WebSocket server.

**Decision**: VOICE_* messages (VOICE_JOIN, VOICE_LEAVE, VOICE_SIGNAL, VOICE_STATE) are NOT emitted as type `EVENT`, NOT assigned an `eventId`, and NOT stored in the replay ring buffer.

**Rationale**:
- Voice signaling data (SDP offers/answers, ICE candidates) is connection-specific and meaningless after the original peer connection is gone.
- Replaying voice join/leave states on reconnect would create stale/incorrect voice membership state.
- Voice membership is inherently tied to an active WebSocket connection — if the connection drops, the peer connections are already dead.
- Keeping voice ephemeral keeps the event buffer clean and focused on session state that can be meaningfully replayed.

**Rule**: On reconnect, clients must re-join voice by sending `VOICE_JOIN` after receiving WELCOME/SNAPSHOT. The server cleans up voice membership automatically on disconnect or LEAVE_SESSION.

## 2026-03-01 — Supabase for persistence + auth, live state stays in-memory

**Context**: Major architecture upgrade to add user accounts, persistent friends, settings, session history, and JWT auth. Must decide what moves to Supabase and what stays in-memory.

**Decision**: Supabase handles auth (JWT), user profiles, friends, session metadata, and meaningful event history. Live session state (`Map<sessionId, SessionState>`), participant locations, presence, voice membership, event ring buffer, rate limiting, and WS connection mappings all remain in-memory.

**Rationale**:
- Live session operations require sub-millisecond latency — DB round-trips are unacceptable for 1/sec location updates and real-time presence.
- The reconnect replay path (ring buffer → SNAPSHOT + EVENTS) must never depend on a DB query.
- Supabase persistence is eventual-consistency for history/analytics only. In-memory state is always authoritative.
- High-frequency location updates (1/sec/user) have no historical value per PRD and must NOT be written to DB.
- Async fire-and-forget DB writes ensure Supabase latency/downtime doesn't block session operations.

**Rule**: Any new persistent feature must go through Supabase. Any real-time/low-latency feature must stay in-memory. These boundaries must not blur.

## 2026-03-01 — JWT replaces random token; participantId resolved server-side

**Context**: Moving from random UUID tokens to Supabase JWT for authentication. Need to decide how the WS handshake changes.

**Decision**: The HELLO payload's `token` field now carries a Supabase JWT. `participantId` becomes optional in HELLO (not needed for JWT auth because the server resolves it from `userId + sessionId`). During migration, if the token is not a valid JWT, the server falls back to legacy random token matching (requires `participantId`).

**Rationale**:
- Server-side participant resolution is more secure (clients can't impersonate participants).
- Reconnect is simpler (client only needs JWT + sessionId, no need to persist a random token).
- Dual-mode detection (JWT vs UUID) allows gradual migration without breaking existing clients.
- JWT verification is local (using SUPABASE_JWT_SECRET) — no network call on the hot path.

**Rule**: Once all clients are migrated to JWT auth, remove legacy anonymous token support entirely (Phase M5).

## 2026-03-01 — Friend model: single-row bidirectional

**Context**: Need to model friend relationships in Postgres.

**Decision**: Use a single row per friendship with `requester_id` and `addressee_id`. Status is `pending`, `accepted`, or `blocked`. Query bidirectionally with `WHERE requester_id = me OR addressee_id = me`.

**Rationale**:
- Single row avoids data duplication (vs. two-row symmetric model).
- `requester_id` / `addressee_id` naming makes the request direction clear.
- RLS policies can easily enforce that only the addressee can accept/reject.
- Block status can be set by either party.

## 2026-03-01 — Async batched event persistence

**Context**: Need to persist meaningful session events to Supabase without killing real-time performance.

**Decision**: Buffer events in-memory and flush to DB in batches (every 5 seconds or 50 events). Location updates are never persisted. On flush failure, log and drop the batch — in-memory state is authoritative.

**Rationale**:
- Synchronous DB writes on every event would add 50-200ms latency to broadcast.
- Batching amortizes the overhead (one INSERT per batch instead of per event).
- Location updates at 1/sec/user would generate massive DB load with zero historical value.
- Dropping failed batches is acceptable because this is history/analytics data, not critical state.

**Rule**: Cap flush buffer at 500 events per session. If DB is down, buffer overflows silently drop oldest events.

## 2026-07-15 — Phase 3 safety contract: SOS replayable, battery not an event, dedicated NOT_ARRIVED

**Context**: Phase 3 (Batch 19+) adds SOS, arrival pings, and battery broadcast. P3-01 (ZAK-5) locks the wire contract in `packages/shared` before any backend/mobile work.

**Decision 1 — SOS + arrival are durable, replayable `EVENT`s.** `SOS_RAISED`/`SOS_CLEARED`/`ARRIVAL_PINGED` get monotonic `eventId`s, sit in the replay ring buffer, and are reflected in `SNAPSHOT` (`activeSos[]`, per-row `sos`/`arrived`). Unlike voice, *missing* a safety message matters — a reconnecting participant must learn an SOS is still active.

**Decision 2 — Battery is presence enrichment, NOT an event.** `LOC_UPDATE` gains optional `battery` (0..1) / `charging`; they ride `ParticipantState`, echo into `LOCATION_UPDATED.data` and `SNAPSHOT` rows. No `BATTERY_LOW` event kind. Rationale: battery is high-frequency and low-value-on-replay (like location); a dedicated event would just add event-stream noise. The low-battery badge (`battery < 0.15 && !charging`) is derived client-side.

**Decision 3 — Dedicated `NOT_ARRIVED` error, not `BAD_MESSAGE`.** An `ARRIVAL_PING` from outside `ARRIVAL_RADIUS_M` is a well-formed message failing a business rule, not a malformed one. A distinct code lets the client show a precise "you're not there yet" message and keeps `BAD_MESSAGE` meaning "protocol/schema violation" only.

**Server sources SOS location.** `SOS_RAISED` lat/lng come from the sender's last server-known location, never a client-supplied position; `null` when unknown (no camera-snap). SOS **persists** across the sender's disconnect — only `CLEAR_SOS` (owner-only) or session end removes it.
