# Waypoints – Architecture (MVP)

## Overview
MVP uses a single Node.js backend with:
- HTTP endpoints for session create/join metadata
- WebSocket server for real-time presence + location updates + destination updates

Mobile client is React Native and communicates via:
- HTTP for create/join
- WebSocket for realtime sync

## Components

### Mobile (apps/mobile)
- Screens:
  - Home: create/join session
  - Session: map + presence list + destination panel
- Services:
  - Location service: polls GPS and sends updates (1/sec)
  - WS client: connect, handshake, send updates, apply events
- State:
  - Session state: participants + destination + connection state
  - lastEventId tracking for reconnect

### Backend (services/api)
- HTTP API
  - POST /sessions -> creates session and returns joinCode
  - POST /sessions/join -> validates joinCode and returns sessionId + token (MVP token can be random)
- WebSocket server
  - Handles HELLO handshake (auth + lastEventId)
  - Stores in-memory session state
  - Broadcasts ordered events to session participants

## In-memory State Model (MVP)
SessionStore:
- sessions: Map<sessionId, SessionState>

SessionState:
- sessionId
- joinCode
- participants: Map<participantId, ParticipantState>
- destination: { lat, lng, label } | null
- lastEventId: number (monotonic per session)
- eventBuffer: ring buffer of last K events (for reconnect replay)

ParticipantState:
- participantId
- displayName (optional)
- lastLocation: { lat, lng, speed, heading, accuracy, ts }
- status: online|stale|offline
- lastSeenTs
- connId (current connection if online)

## Scaling Later (not MVP)
- Replace in-memory session store with Redis for shared state
- Use pub/sub for cross-instance broadcasts
- Keep protocol unchanged

## Phase 0 – MVP Context Summary

### 1) MVP Scope

Waypoints is a real-time social location sharing app. The MVP delivers:

- **Session lifecycle**: Create a session (returns join code), join via code (returns sessionId + token).
- **Live location sharing**: Participants send GPS updates at ~1/sec; all participants see each other on a live map.
- **Presence**: Three states — `online`, `stale` (no update for N seconds), `offline` (disconnected).
- **Destination marker**: Host sets a destination (`lat`, `lng`, `label`); all participants see it.
- **Reconnect-safe sync**: Server maintains a monotonic `eventId` per session and a ring buffer of recent events. On reconnect, the client sends `lastEventId` in `HELLO`; the server replies with `SNAPSHOT` + missed `EVENTS`.
- **Structured errors**: Malformed WS messages get an `ERROR` response with `code` + `message`.
- **Chat**: Explicitly marked optional (phase 1.5), not MVP-critical.

**Acceptance bar**: 20 concurrent users in one session, 1 update/sec, no data persistence beyond in-memory session lifetime.

### 2) Architectural Constraints

| Constraint | Detail |
|---|---|
| Single backend instance | Node.js, Fastify for HTTP, `ws` for WebSockets |
| In-memory state only | `Map<sessionId, SessionState>` — no database, no Redis |
| Two transport layers | HTTP for session create/join; WebSocket for all real-time sync |
| Token model | Random token issued at join — no auth provider in MVP |
| Mobile client | React Native + Expo |
| TypeScript everywhere | Backend, mobile, shared types |
| No long-term storage | Only last known location kept during session lifetime |

### 3) Real-Time Invariants

1. **Monotonic eventId**: `eventId` is server-assigned, increments by 1 per session, never gaps.
2. **Reconnect replay**: Client sends `lastEventId` in `HELLO`. Server sends `SNAPSHOT` (full current state) then `EVENTS` (missed range `fromEventId → toEventId`). Client applies in order.
3. **Duplicate rejection**: Client must ignore events with `eventId ≤ lastEventId`.
4. **Presence derivation**: `online` = active WS connection + recent update; `stale` = connected but no update for N seconds; `offline` = WS disconnected.
5. **Rate limiting**: Server drops `LOC_UPDATE` if client sends faster than allowed rate (1/sec MVP).
6. **Ordered broadcast**: All session events are broadcast to all participants in `eventId` order.
7. **Message shape enforcement**: Every WS message must be `{ "type": string, "payload": object }`. Invalid → `ERROR` response.
8. **Handshake sequence**: `HELLO` → `WELCOME` → `SNAPSHOT` → (optional `EVENTS`) — strict order.

### 4) Explicit Non-Goals

- Voice / proximity chat
- Background location (always-on tracking)
- Multi-stop route editing
- Payments / subscriptions
- Public feed / social features
- Long-term location history
- Multi-instance / horizontal scaling
- Redis / pub-sub
- Docker / Kubernetes
- Any paid infrastructure

### 5) Infrastructure Constraints (What We Must NOT Introduce)

- **No Redis** — in-memory only until a task explicitly says otherwise.
- **No Docker / Kubernetes** — runs locally via `npm` scripts.
- **No external databases** — no Postgres, SQLite, Mongo, etc.
- **No paid services** — no cloud hosting, no third-party APIs requiring keys for MVP core.
- **No auth providers** — random token at join is sufficient.
- **No new dependencies without justification** — every `npm install` must be documented.
- **Single process only** — no worker threads, no clustering for MVP.

### 6) Risk Areas

| Risk | Impact | Mitigation |
|---|---|---|
| **Ring buffer overflow** | If buffer size K is too small and a client is offline too long, missed events are lost | Server detects gap → sends full `SNAPSHOT` instead of `EVENTS`. Must implement this fallback. |
| **Stale/offline threshold tuning** | Wrong N value makes presence unreliable | Make threshold configurable (env var). Start with 10s stale, 30s offline. |
| **Race between HTTP join and WS HELLO** | Client might open WS before join response arrives | Client must wait for HTTP join response (gets `participantId` + `token`) before opening WS. |
| **Event ordering under concurrent updates** | Two `LOC_UPDATE`s from different clients arriving simultaneously | Single-threaded Node.js event loop serializes. Not a risk at MVP scale, but the `eventId` assignment must be synchronous (no async gap). |
| **Memory growth** | Sessions never cleaned up → OOM | Implement session TTL / cleanup on empty. |
| **Client clock skew** | `ts` from client may differ wildly from server | Server stamps its own `ts` on events. Client `ts` is informational only. |
| **Location permission denied** | App must not crash | PRD explicit: show clear message, degrade gracefully. |
| **WS message validation** | Unvalidated payloads cause runtime crashes | Validate every incoming message against schema before processing. Use a lightweight validator (e.g., Zod). |

## Phase 1 – System Design Plan

### Package Manager

**npm** with workspaces. Chosen over pnpm for Expo/React Native Metro bundler compatibility. Ships with Node.js — zero extra install.

### Monorepo Layout

```
Waypoints/
├── packages/shared/          # Shared TS types + Zod validators
├── services/api/             # Fastify + ws backend
├── apps/mobile/              # React Native (Expo)
├── package.json              # Root: npm workspaces
├── tsconfig.base.json        # Shared TS compiler options
├── .eslintrc.json
├── .prettierrc
└── .gitignore
```

### Dependency Manifest

**Root devDependencies**: typescript, eslint, @typescript-eslint/parser, @typescript-eslint/eslint-plugin, prettier, eslint-config-prettier.

**packages/shared**: zod (runtime validation + type inference).

**services/api**: fastify, ws, @types/ws, uuid, zod (boot config validation, WP-105), pino-pretty (dev-friendly log formatting, WP-104 — Pino itself ships with Fastify), tsx (dev), vitest (dev), @vitest/coverage-v8 (dev — coverage floor, WP-103).

**apps/mobile**: expo, expo-location, react-native-maps, react, react-native, zustand.

No ORMs, no Express, no Socket.IO, no Redis.

### Shared Types Strategy

`packages/shared` consumed via npm workspaces (`"@waypoints/shared": "*"`). Contains:
- `types.ts` — domain types
- `ws-types.ts` — discriminated union for all WS messages
- `validators.ts` — Zod schemas for inbound messages

### In-Memory Store Design

- `SessionStore`: singleton `Map<sessionId, SessionState>`
- `EventBuffer`: ring buffer (capacity K, default 1000)
- Reconnect: if `lastEventId >= oldestEventId` → replay EVENTS; else → SNAPSHOT only
- Cleanup: `setInterval` every 60s, remove empty sessions older than 2h TTL

### Rate Limiting

Per-participant timestamp check on LOC_UPDATE. Drop if `< 900ms` since last. Configurable via `LOC_UPDATE_MIN_INTERVAL_MS` env var.

### Testing

vitest for backend (unit + integration). Tests in `services/api/src/__tests__/`. In-process Fastify instance, no external server.

### Dev Scripts

```bash
npm install                    # all workspaces
npm run build:shared           # compile shared types
npm run dev:api                # tsx watch src/index.ts
npm run dev:mobile             # expo start
npm test                       # vitest run (backend)
npm run lint                   # eslint across all workspaces
```

### MVP vs Future Boundary

| MVP | Future |
|---|---|
| In-memory Map | Redis |
| Single instance | Redis pub/sub cross-instance |
| Random token | JWT / OAuth |
| State lost on restart | Persisted sessions |
| Timestamp rate limit | Token bucket |
| Manual test/lint | GitHub Actions CI |

## Batch 9 – Real App Upgrades

### Changes Summary

**Backend:**
- **CORS**: `@fastify/cors` registered with configurable origin (default: allow all in dev).
- **HTTP validation**: Display name sanitization (trim + truncate to 30 chars), join code format validation (`/^[A-Z0-9]{6}$/`), session capacity check (409 if full, default 50 participants).
- **Health endpoint**: Now returns `{ status, uptime, sessions, timestamp }`.
- **Host-only destination**: Only the session creator (`hostParticipantId`) can SET_DESTINATION or CLEAR_DESTINATION. Non-host gets `FORBIDDEN` error.
- **CLEAR_DESTINATION**: New message type that nulls the destination and broadcasts `DESTINATION_CLEARED` event with `clearedBy`.
- **WELCOME**: Now includes `hostParticipantId` so client knows who the host is.
- **DESTINATION_SET**: Now includes `setBy` (participantId of who set it).
- **Session info**: `GET /sessions/:id` now returns `lastSeenTs` per participant and `createdAt`.

**Mobile:**
- **AsyncStorage persistence**: Display name and session history stored locally (up to 10 entries).
- **Session history**: Recent sessions list on home screen with tap-to-rejoin and long-press-to-delete.
- **Exponential backoff reconnect**: 1s → 2s → 4s → 8s (max), resets on successful connection.
- **Distance/ETA**: Haversine distance and walking ETA shown in destination panel.
- **Host controls**: Only host sees long-press-to-set-destination and clear destination button. Host badge (👑) shown in presence list and banner.
- **Error boundary**: React error boundary wraps entire app with retry UI.
- **Connection quality**: Reconnect count displayed during reconnection attempts.

**Shared:**
- New types: `ClearDestinationMessage`, `DestinationClearedEvent`, `FORBIDDEN` error code.
- New event kind: `DESTINATION_CLEARED`.
- `WelcomeMessage` now includes `hostParticipantId`.
- `DestinationSetEvent.data` now includes `setBy`.

**Tests:** 44 total (was 34). New tests cover host-only destination, FORBIDDEN for non-host, CLEAR_DESTINATION, DESTINATION_CLEARED in SNAPSHOT, WELCOME hostParticipantId, HTTP validation, health endpoint metadata.

**New dependencies:**
- `@fastify/cors@^9.0.0` (backend CORS)
- `@react-native-async-storage/async-storage@^2.1.0` (mobile persistence)

## Batches 10-15 – App Store Readiness

### Build Infrastructure (Batch 10)
- Converted `app.json` → `app.config.ts` with dynamic config (dev/preview/production bundle IDs)
- Created `eas.json` with three build profiles: development (simulator), preview (TestFlight), production
- Created `metro.config.js` for npm workspace monorepo symlink resolution
- Created `babel.config.js` with `babel-preset-expo`
- Bundle identifiers: `com.waypoints.app` (prod), `.dev` (dev), `.preview` (preview)
- iOS `buildNumber` and Android `versionCode` management, `usesNonExemptEncryption: false`
- Installed: `expo-dev-client`, `expo-splash-screen`, `expo-haptics`, `expo-status-bar`, `expo-constants`

### App Assets (Batch 11)
- Generated app icon (1024x1024), splash screen (1284x2778), adaptive icon (1024x1024), favicon (48x48)
- SVG→PNG pipeline via sharp (`scripts/generate-assets.js`)
- Indigo-to-violet gradient icon with map pin + "WAYPOINTS" text
- Splash screen: branded indigo background with centered pin icon

### UI Polish (Batch 12)
- Added theme colors: `destinationBg`, `destinationBorder`, `destinationText`, `danger`, `dangerLight`
- Replaced all hardcoded hex colors with theme references
- Added AbortController-based 10-second timeouts to all HTTP fetch calls
- Dynamic map initial region based on user's location (fallback: center of US)
- Added `expo-status-bar` component in App.tsx
- Android safe area padding

### Production Deployment (Batch 13)
- Multi-stage Dockerfile: Node 20 Alpine, builds shared + API, production-only deps in final image
- `fly.toml` config: IAD region, 256MB VM, shared CPU, auto-stop/auto-start, HTTPS-forced
- `.dockerignore` excluding mobile app, docs, and dev files
- Health check endpoint used for container health monitoring

### App Store Prep (Batch 14)
- Privacy policy (`docs/PRIVACY_POLICY.md`): covers location data, retention, children's privacy
- App Store metadata (`docs/APP_STORE_METADATA.md`): description, keywords, category, age rating, screenshots guide, review notes
- Manual actions guide (`docs/MANUAL_ACTIONS.md`): step-by-step for Apple Developer, EAS, Fly.io, App Store Connect

### Final State
- **Backend**: 10 source files, 6 test files, 44 tests passing, production-ready Docker image
- **Mobile**: 14 source files, Expo SDK 52, EAS build-ready with 3 profiles
- **Shared**: 4 source files, full WS protocol types + validators
- **Docs**: PRD, Architecture, WS Protocol, Privacy Policy, App Store Metadata, Manual Actions
- **Total**: ~60 source files, ~11,000 lines of code (excluding tests)

## Phase 2 – Voice Chat (Batch 18)

### What Changed

**Shared (`packages/shared`)**:
- Added VOICE_* TypeScript types: `VoiceJoinMessage`, `VoiceLeaveMessage`, `VoiceSignalMessage`, `ServerVoiceSignalMessage`, `VoiceStateMessage`
- Added Zod schemas: `voiceJoinPayloadSchema`, `voiceLeavePayloadSchema`, `voiceSignalPayloadSchema`
- Extended `ClientMessage` and `ServerMessage` unions with voice message types
- New exported type: `ValidatedVoiceSignalPayload`

**Backend (`services/api`)**:
- `state/session-store.ts`: Added `voiceMembers: Set<string>` to `FullSessionState`
- `ws/voice.ts`: New handler module with `handleVoiceJoin`, `handleVoiceLeave`, `handleVoiceSignal`, `cleanupVoiceMember`
- `ws/dispatcher.ts`: Routes `VOICE_JOIN`, `VOICE_LEAVE`, `VOICE_SIGNAL` to voice handlers
- `ws/handler.ts`: Calls `cleanupVoiceMember` on disconnect
- `ws/leave.ts`: Calls `cleanupVoiceMember` on LEAVE_SESSION
- **Payload validation**: SDP offer/answer ≤ 40KB, ICE candidates ≤ 8KB
- **Security**: Sender must be in voiceMembers; recipient must be in same session AND voiceMembers

**Tests**: 58 total (was 44). 14 new tests in `voice.test.ts` covering:
- VOICE_JOIN/LEAVE membership management + broadcast
- VOICE_SIGNAL sender/recipient validation
- VOICE_SIGNAL forwarding to intended recipient only (not leaked to others)
- Payload size limit enforcement (40KB SDP, 8KB ICE)
- Bad payload rejection
- No voice events in replay ring buffer
- Cleanup on disconnect and LEAVE_SESSION
- Auth required (VOICE_JOIN before HELLO rejected)

**Mobile (`apps/mobile`)**:
- `services/voice.ts`: Voice service with `joinVoice()`, `leaveVoice()`, `sendSignal()` functions
- `services/ws-client.ts`: Extended to handle incoming `VOICE_SIGNAL` and `VOICE_STATE` messages
- `state/session-store.ts`: Added `voiceMembers` set and `voiceState` tracking
- `hooks/useVoiceChat.ts`: Full WebRTC hook with mic permission, peer connections, mute/PTT, multi-peer mesh
- `SessionScreen.tsx`: Voice (beta) UI — join/leave toggle, mute, push-to-talk, peer count indicator

### Design Decisions
- Voice messages are **ephemeral** — NOT emitted as EVENT, NOT stored in ring buffer, NOT replayed on reconnect
- Mesh topology for audio (each participant connects to all others) — suitable for ≤ 8 participants
- STUN-only for NAT traversal (free tier); TURN server can be added later if needed
- No audio persistence, no server-side media processing

### Next Steps
- Monitor NAT traversal success rate; add TURN fallback if needed
- Consider SFU architecture if voice groups regularly exceed 8 participants
- Add visual audio level indicators
- Add spatial/proximity audio (tie volume to map distance)

---

## Phase 3 – Supabase Architecture Upgrade (Phase 0: Design)

### Overview

Major architecture upgrade introducing Supabase for persistent user accounts, friends, settings, session metadata, and session event history. Live session state remains ephemeral and in-memory. No Redis, no multi-instance, single backend.

### Goals

1. **User accounts**: Register, login, logout via Supabase Auth (email/password, extensible to OAuth later)
2. **Persistent auth**: JWT-based authentication for all REST and WebSocket endpoints
3. **Persistent friends list**: Send/accept/reject/remove friend requests; query friends
4. **Persistent user settings**: Display name, avatar, preferences stored in Postgres
5. **Persistent session metadata**: Who created what session, when, with what join code
6. **Persistent session event history**: Meaningful events (joins, leaves, chat, destination changes) logged to Postgres for post-session review

### Architectural Constraints (Unchanged)

| Constraint | Detail |
|---|---|
| Single backend instance | Node.js, Fastify for HTTP, `ws` for WebSockets |
| No Redis | Not introduced |
| No multi-instance | No horizontal scaling |
| No Docker changes | Existing Dockerfile untouched |
| TypeScript everywhere | Backend, mobile, shared types |
| Backend validates all input | Zod schemas, JWT verification |
| No high-frequency location in DB | Only meaningful events persisted |
| Rate limiting in-memory | Per-participant timestamp check stays |

### What Remains In-Memory

| Component | Rationale |
|---|---|
| `Map<sessionId, SessionState>` | Live session state must be low-latency; DB round-trips unacceptable for real-time |
| Participant locations | 1/sec/user — too high-frequency for DB writes |
| Presence status (online/stale/offline) | Derived from connection + timing, ephemeral |
| Voice membership (`voiceMembers`) | Connection-scoped, ephemeral |
| Event ring buffer (`EventBuffer`) | For WS reconnect replay; DB too slow for this path |
| Rate limiting timestamps | Per-connection, sub-second granularity |
| WebSocket connection map | Connection ↔ participant binding |

### What Moves to Supabase

| Component | Table | Notes |
|---|---|---|
| User accounts | `auth.users` (Supabase managed) | Email/password, JWT issuance |
| User profiles | `profiles` | Display name, avatar, settings |
| Friend relationships | `friendships` | Request/accept/reject/block model |
| Session metadata | `sessions` | Creation record, join code, host, status |
| Session participants | `session_participants` | Who joined which session |
| Meaningful session events | `session_events` | Joins, leaves, chat, destination — NOT locations |

### Postgres Schema

```sql
-- ============================================================
-- profiles: extends Supabase auth.users with app-specific data
-- ============================================================
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT CHECK (char_length(display_name) <= 30),
  avatar_url TEXT,
  settings JSONB NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Auto-create profile on signup via Supabase trigger
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, display_name)
  VALUES (NEW.id, NEW.raw_user_meta_data->>'display_name');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- friendships: bidirectional, single-row per relationship
-- ============================================================
CREATE TABLE friendships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  addressee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'blocked')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (requester_id, addressee_id),
  CHECK (requester_id <> addressee_id)
);

CREATE INDEX idx_friendships_addressee ON friendships(addressee_id, status);
CREATE INDEX idx_friendships_requester ON friendships(requester_id, status);

-- ============================================================
-- sessions: persistent session metadata
-- ============================================================
CREATE TABLE sessions (
  id UUID PRIMARY KEY,
  join_code TEXT NOT NULL UNIQUE,
  host_user_id UUID NOT NULL REFERENCES profiles(id),
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'ended')),
  destination JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ended_at TIMESTAMPTZ
);

CREATE INDEX idx_sessions_join_code ON sessions(join_code);
CREATE INDEX idx_sessions_host ON sessions(host_user_id);

-- ============================================================
-- session_participants: who joined which session
-- ============================================================
CREATE TABLE session_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  participant_id UUID NOT NULL,
  display_name TEXT,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at TIMESTAMPTZ,
  UNIQUE (session_id, user_id)
);

CREATE INDEX idx_session_participants_session ON session_participants(session_id);
CREATE INDEX idx_session_participants_user ON session_participants(user_id);

-- ============================================================
-- session_events: meaningful events only (NOT location updates)
-- ============================================================
CREATE TABLE session_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  event_id INTEGER NOT NULL,
  kind TEXT NOT NULL,
  data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_session_events_session ON session_events(session_id, event_id);
```

### RLS Policies

```sql
-- ── Profiles ──
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view profiles"
  ON profiles FOR SELECT USING (true);

CREATE POLICY "Users can insert own profile"
  ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE USING (auth.uid() = id);

-- ── Friendships ──
ALTER TABLE friendships ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own friendships"
  ON friendships FOR SELECT
  USING (auth.uid() = requester_id OR auth.uid() = addressee_id);

CREATE POLICY "Users can send friend requests"
  ON friendships FOR INSERT
  WITH CHECK (auth.uid() = requester_id);

CREATE POLICY "Users can update friendships they received"
  ON friendships FOR UPDATE
  USING (auth.uid() = addressee_id);

CREATE POLICY "Users can delete own friendships"
  ON friendships FOR DELETE
  USING (auth.uid() = requester_id OR auth.uid() = addressee_id);

-- ── Sessions ──
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Participants can view their sessions"
  ON sessions FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM session_participants sp
      WHERE sp.session_id = sessions.id AND sp.user_id = auth.uid()
    )
  );

CREATE POLICY "Authenticated users can create sessions"
  ON sessions FOR INSERT
  WITH CHECK (auth.uid() = host_user_id);

CREATE POLICY "Host can update own sessions"
  ON sessions FOR UPDATE
  USING (auth.uid() = host_user_id);

-- ── Session Participants ──
ALTER TABLE session_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Participants can view co-participants"
  ON session_participants FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM session_participants sp
      WHERE sp.session_id = session_participants.session_id
        AND sp.user_id = auth.uid()
    )
  );

-- ── Session Events ──
ALTER TABLE session_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Participants can view session events"
  ON session_events FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM session_participants sp
      WHERE sp.session_id = session_events.session_id
        AND sp.user_id = auth.uid()
    )
  );
```

### JWT Verification Flow

#### REST Endpoints

```
Client request:
  Authorization: Bearer <supabase_jwt>
      │
      ▼
Fastify preHandler hook:
  1. Extract token from Authorization header
  2. Verify JWT signature using SUPABASE_JWT_SECRET (local, no network call)
  3. Decode payload → extract `sub` claim (userId)
  4. Check token expiry (`exp` claim)
  5. Attach userId to request context: request.userId = sub
  6. If invalid/expired → 401 Unauthorized
      │
      ▼
Route handler executes with authenticated userId
```

**Implementation**: Use `jsonwebtoken` library for local verification. No network call to Supabase for every request. The JWT secret is a static env var from the Supabase dashboard.

#### WebSocket Handshake

```
Client sends HELLO:
  { type: "HELLO", payload: { sessionId, token: <jwt>, lastEventId } }
      │
      ▼
Server HELLO handler:
  1. Verify JWT signature using SUPABASE_JWT_SECRET
  2. Check token expiry
  3. Extract userId from `sub` claim
  4. Look up session by sessionId
  5. Find participant in session where participant.userId === userId
  6. If no match → ERROR { code: "UNAUTHORIZED" }
  7. Bind connection: conn.userId = userId, conn.participantId = found participant
  8. Proceed with WELCOME → SNAPSHOT → EVENTS
```

**Key change**: The server resolves `participantId` from `userId + sessionId` instead of the client sending it. This is more secure (client can't impersonate another participant) and simpler for reconnect (client only needs JWT + sessionId).

#### Dual-Mode Auth (Migration Period)

During migration, both auth modes are supported:
1. **JWT mode**: `token` is a valid JWT → extract userId, resolve participant
2. **Legacy mode**: `token` is a UUID → match against stored random token (existing behavior)

Detection: attempt JWT verification first. If it fails (not a valid JWT format), fall back to legacy token matching.

### Friend Relationship Model

Single-row bidirectional model:

```
User A sends request to User B:
  INSERT friendships (requester_id=A, addressee_id=B, status='pending')

User B accepts:
  UPDATE friendships SET status='accepted' WHERE requester_id=A AND addressee_id=B

Query "my friends":
  SELECT * FROM friendships
  WHERE (requester_id = me OR addressee_id = me) AND status = 'accepted'

User A or B removes friendship:
  DELETE FROM friendships WHERE id = ...
```

**REST endpoints:**
- `GET /friends` — list accepted friends + pending requests
- `POST /friends/request` — send friend request (body: `{ userId }`)
- `POST /friends/accept` — accept request (body: `{ friendshipId }`)
- `POST /friends/reject` — reject request (body: `{ friendshipId }`)
- `DELETE /friends/:friendshipId` — remove friendship

### Session Metadata & Participant Storage

**On session create (`POST /sessions`):**
1. Create in-memory `SessionState` (as today)
2. INSERT into `sessions` table (async, non-blocking)
3. INSERT into `session_participants` (host as first participant, async)

**On session join (`POST /sessions/join`):**
1. Add participant to in-memory session (as today)
2. INSERT into `session_participants` (async)

**On session end (cleanup):**
1. Remove from in-memory map (as today)
2. UPDATE `sessions` SET `status = 'ended'`, `ended_at = now()` (async)

**Schema notes:**
- `session_participants.participant_id` stores the ephemeral in-session ID for event correlation
- `session_participants.user_id` links to the authenticated user
- `sessions.id` matches the in-memory `sessionId` (UUID generated at create time)

### Session Event Logging Strategy

**Problem**: Writing every event to the DB synchronously would kill performance.

**Solution**: Async batched inserts.

```
Event occurs in session
    │
    ▼
Is it a meaningful event? (not LOCATION_UPDATED)
    │ yes
    ▼
Add to in-memory event flush buffer (per session)
    │
    ▼
Flush triggers (whichever comes first):
  • Buffer size ≥ 50 events
  • Timer fires (every 5 seconds)
  • Session ends / cleanup
    │
    ▼
Batch INSERT into session_events (async, fire-and-forget)
    │
    ▼
On failure: log warning, drop batch (session state is authoritative in-memory)
```

**Events persisted:**
- `PARTICIPANT_JOINED`
- `PARTICIPANT_LEFT`
- `DESTINATION_SET`
- `DESTINATION_CLEARED`
- `CHAT_MESSAGE`

**Events NOT persisted:**
- `LOCATION_UPDATED` — too high frequency, no historical value per PRD
- `VOICE_*` — ephemeral by design

### ConnState Extension

```typescript
// Before
interface ConnState {
  ws: WebSocket;
  sessionId: string | null;
  participantId: string | null;
  connId: string;
}

// After
interface ConnState {
  ws: WebSocket;
  sessionId: string | null;
  participantId: string | null;
  userId: string | null;  // NEW: Supabase auth user ID
  connId: string;
}
```

### Reconnect-Safe eventId Model (Unchanged)

The eventId model is **completely preserved**:
1. Events are still monotonically numbered per session (in-memory)
2. Ring buffer still holds last K events for replay
3. HELLO still sends `lastEventId`; server replies with SNAPSHOT + EVENTS
4. DB event logging is async and has no bearing on the reconnect path
5. If a client reconnects, the in-memory ring buffer serves the replay — never the DB
6. The DB `session_events.event_id` column stores the same IDs for correlation/history, but is never queried during reconnect

### WS-PROTOCOL Changes Required

1. **HELLO payload**: `participantId` removed (server resolves from JWT userId + sessionId). `token` now carries a Supabase JWT (or legacy UUID during migration).
2. **New error code**: `AUTH_EXPIRED` — sent when JWT has expired; client should refresh token and reconnect.
3. **HTTP endpoints**: All mutating endpoints require `Authorization: Bearer <jwt>` header.
4. **No other protocol changes**: WELCOME, SNAPSHOT, EVENTS, EVENT, all message types remain identical.

### Migration Plan: Anonymous → Authenticated Sessions

| Phase | Scope | Backward Compatible |
|---|---|---|
| **M1: Backend infra** | Add Supabase client, JWT verifier, DB service, schema migration. REST endpoints support both auth modes. WS HELLO supports dual token detection. | Yes — legacy anonymous flow still works |
| **M2: Persistence layer** | Session create/join writes to DB. Event flush buffer active. Friends API endpoints added. Profile endpoints added. | Yes — in-memory state unchanged |
| **M3: Mobile auth** | Add Supabase Auth to mobile. Login/register screens. HTTP calls include JWT. WS HELLO sends JWT. | Yes — can still use legacy flow on old clients |
| **M4: Mobile features** | Friends list UI, profile/settings UI, session history UI. | Yes |
| **M5: Cleanup** | Remove legacy anonymous token support. All endpoints require JWT. Remove `token` from `ParticipantState`. Update all tests. | No — breaking change, requires app update |

### Environment Variables (New)

| Variable | Description | Where |
|---|---|---|
| `SUPABASE_URL` | Supabase project URL (`https://xxx.supabase.co`) | Backend `.env` |
| `SUPABASE_ANON_KEY` | Supabase anon/public key (safe for client-side) | Mobile `.env` / app config |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service role key (server-side only, bypasses RLS) | Backend `.env` |
| `SUPABASE_JWT_SECRET` | JWT signing secret (for local verification) | Backend `.env` |

### New Dependencies

| Package | Where | Justification |
|---|---|---|
| `@supabase/supabase-js` | Backend + Mobile | Official Supabase client for DB operations and mobile auth |
| `jsonwebtoken` | Backend | Local JWT verification without network calls (fast path for WS handshake) |
| `@types/jsonwebtoken` | Backend (dev) | TypeScript types for jsonwebtoken |

### Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| Supabase latency on DB writes | Slow session create/join | All DB writes are async fire-and-forget; in-memory is authoritative |
| JWT expiry during long session | User disconnected | Client monitors token expiry, refreshes proactively before expiry |
| Supabase downtime | Auth fails, DB writes fail | Auth: cached JWT still valid until expiry. DB: session continues in-memory |
| Migration period complexity | Two auth paths to maintain | Clear dual-mode detection; remove legacy in M5 |
| Event flush buffer memory | Unbounded growth if DB is down | Cap buffer at 500 events per session; drop oldest on overflow |
| Profile creation race | Signup trigger might fail | Upsert pattern in profile creation; client retries |

---

## Phase 3 — Safety layer (implemented)

`RAISE_SOS` / `CLEAR_SOS` / `ARRIVAL_PING` are handled in `services/api/src/ws/safety.ts`.
State lives on the existing session map: `sosActive: Map<participantId, {note, ts}>`
and `arrived: Set<participantId>`, both surfaced in `SNAPSHOT`. Battery and
charging live on `ParticipantState` and ride the `LOC_UPDATE` stream.

Unlike voice, these are durable: they are pushed to the ordered event stream,
buffered for replay, and included in the snapshot. A participant reconnecting
mid-emergency must learn that an SOS is still active — this is the first
feature where *missing* a message is a safety failure rather than a cosmetic one.

New dependency: `expo-battery` (~10.0.8), mobile only, read foreground-only
alongside the existing location watcher. No background access is added.

### Connection liveness

`ws/handler.ts` runs a ping/pong sweep at `WS_HEARTBEAT_INTERVAL_MS` (default
15s) and terminates connections that miss two consecutive sweeps. Before this,
a half-open TCP connection left a participant `online` indefinitely: presence
only forces `offline` when `connId === null`, and `connId` is cleared by the
close event that a half-open socket never delivers.

`ws/handler.ts` also maintains a `sessionId → Set<ConnState>` index so that
broadcast cost is O(session participants) rather than O(all connections on the
process). Measured results: `docs/CAPACITY.md`.
