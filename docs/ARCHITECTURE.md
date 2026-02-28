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

**services/api**: fastify, ws, @types/ws, uuid, tsx (dev), vitest (dev).

**apps/mobile**: expo, expo-location, react-native-maps, react, react-native, zustand.

Total: 11 production + 5 dev. No ORMs, no Express, no Socket.IO, no Redis.

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