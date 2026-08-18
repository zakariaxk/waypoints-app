# Waypoints — Finishing Implementation Plan

> **Status 2026-08-17:** W1–W8, W10–W16 are **implemented and merged to
> `zakariakhan/finishing-plan-implementation`** (PR #7). Backend 73 → 91
> tests, mobile 0 → 14, mobile lint 36 errors → 0, CI green.
> Remaining: **W9** (reconnect UX states — the store and client expose
> everything needed, the session screen does not surface all three yet),
> **W17** (one-command demo script), **WF1** (spatial voice — blocked on
> verifying per-peer gain support, see §5), **WF2** (trip replay).
> Deployment is configured but **not executed** — needs Fly credentials.

Audit date: 2026-08-17 · Repo @ `36cae65` (branch `zakariakhan/zak-5-p3-01-protocol-contract`)
Companion plan for the sibling project: `StabilityNet/docs/FINISHING_PLAN.md`

Baseline established by running, not by reading:

| Check | Result |
|---|---|
| `npm test` (services/api) | **73 passed / 9 files / 8.2s** (README says 44 — stale) |
| `npm run typecheck` (shared, api, mobile) | pass |
| `npm run lint -w apps/mobile` | **fails: 36 errors, 11 warnings** (CI marks non-blocking) |
| mobile tests | **none exist** |

---

## 1. Executive Assessment

| | |
|---|---|
| **Completeness** | **~80%** of its own declared scope. Phases 0–2 shipped and working; Phase 3 is a half-landed contract. |
| **Technical strength** | The WS protocol layer. Discriminated-union types in `packages/shared/src/ws-types.ts`, Zod validation at the dispatcher boundary (`services/api/src/ws/dispatcher.ts:22`), synchronous monotonic `eventId` assignment (`session-store.ts:pushEvent`), ring-buffered replay with an explicit "gap too large → snapshot only" branch. Config validated at boot with aggregated error reporting (`config.ts`). CI gates typecheck+lint+coverage. This is genuinely above student-project baseline. |
| **Biggest weakness** | **The headline feature — "reconnect-safe replay, no missed updates" — is broken on the client.** `apps/mobile/src/state/session-store.ts:applyEvent` drops every event whose `eventId <= lastEventId`, and `applySnapshot` sets `lastEventId = snapshot.latestEventId` *before* the `EVENTS` replay message arrives. Every replayed event is therefore discarded. Server-side replay is correct and tested; the client throws the result away. |
| **Biggest opportunity** | Finish Phase 3 (SOS / arrival / battery). The types, Zod schemas, session state fields, and `docs/WS-PROTOCOL.md` are already written — only the ~120 lines of handlers, the mobile UI, and tests are missing. Highest ratio of demo impact to remaining work. |

---

## 2. Current Architecture

Verified by reading source, not docs.

```
apps/mobile (Expo SDK 54, RN 0.81.5, React 19)
  screens/HomeScreen.tsx (356)   create/join, session history
  screens/SessionScreen.tsx (980) ← the whole live experience, one file
  services/ws-client.ts (219)     singleton WS, exp-backoff reconnect 1s→8s
  services/location.ts (49)       expo-location watchPositionAsync @ 1s
  services/voice.ts + hooks/useVoiceChat.ts (452)  WebRTC mesh, STUN-only
  state/session-store.ts (255)    Zustand; participants Map, chat, voice set
        ↕ ws://  (single connection, JSON {type,payload})
services/api (Fastify 4 + ws 8, tsx dev / node dist prod)
  index.ts          listen() → setupWebSocket(server) → 2 setInterval sweeps
  ws/handler.ts     Map<connId, ConnState>; broadcastToSession scans ALL conns
  ws/dispatcher.ts  JSON.parse → clientMessageSchema.safeParse → switch
  ws/{handshake,location,chat,destination,leave,voice}.ts
  state/session-store.ts  Map<sessionId, FullSessionState>  ← single source of truth
  state/event-buffer.ts   array + shift() ring, capacity 1000
  state/presence.ts       online/stale/offline by lastSeenTs, swept every 5s
  http/routes.ts    POST /sessions, POST /sessions/join, GET /sessions/:id, GET /health
packages/shared   types.ts + ws-types.ts (297) + validators.ts (148, Zod)
```

Deployment: three configs coexist — `Dockerfile`, `render.yaml` (docker runtime, free plan, the one README points at), `fly.toml`. Data model is in-memory only, per the hard constraints in `CLAUDE.md`.

---

## 3. What Works / What Doesn't

### Works (verified)

- **Session lifecycle.** Create → 6-char code (ambiguity-free alphabet, `session-store.ts:37`) → join → HELLO → WELCOME/SNAPSHOT. `http.test.ts` + `handshake.test.ts` cover it, 73 tests green.
- **Server-side event ordering and replay.** `pushEvent` increments and stamps synchronously with no `await` between — the invariant in `ARCHITECTURE.md` §3 holds. `getMissedEvents` correctly returns `null` when `lastEventId < oldest - 1` and `handshake.ts:60` correctly falls back to snapshot-only. Tested at `handshake.test.ts:263`.
- **Inbound validation.** Every client message hits `clientMessageSchema.safeParse` before any handler. Malformed → structured `ERROR`. No handler trusts raw input.
- **Voice signaling.** `ws/voice.ts` is the best-defended file in the repo: membership gate on both sender and recipient, per-signal-type byte caps (40 KB SDP / 8 KB ICE), unicast forwarding only, cleanup on disconnect. 14 tests.
- **Structured logging without PII.** `logInboundMessage` logs routing metadata only; `logging.test.ts` asserts no coordinates or chat text appear at info level.
- **Config validation.** Bad `PORT` exits non-zero naming the variable; `check:env` keeps schema and `.env.example` in sync in CI.

### Partially implemented

- **Phase 3 safety layer.** `RAISE_SOS` / `CLEAR_SOS` / `ARRIVAL_PING` exist in `ws-types.ts:33-49`, in `validators.ts:44-52`, in the `clientMessageSchema` union, in `docs/WS-PROTOCOL.md:161-188`, and `SessionState` carries `sosActive: Map` + `arrived: Set` + per-participant `battery`/`charging`. **No handler exists for any of them.** `dispatcher.ts`'s switch has no cases, so a client sending `RAISE_SOS` gets `BAD_MESSAGE: Unknown message type`. `buildSnapshot` reads `sosActive`/`arrived` — which nothing ever writes. `ErrorCode` includes `NOT_ARRIVED`, emitted nowhere.
- **Battery enrichment.** `locUpdatePayloadSchema` accepts `battery`/`charging`; `handleLocUpdate` ignores both fields and the `LOCATION_UPDATED` event it constructs omits them — while `LocationUpdatedEvent.data` declares both as required. The `as SessionEvent` cast in `pushEvent` (`session-store.ts:139`) is what lets this compile.

### Unfinished

- **Client-side replay.** No `sendRaiseSos`/`sendArrivalPing` in `ws-client.ts`; `applySnapshot`'s type cast drops `battery`, `arrived`, `sos` from snapshot rows.
- **Mobile tests.** Zero. All logic in `session-store.ts`, `geo.ts`, `routing.ts`, `useParticipantETAs.ts` is unverified.
- **Mobile lint.** 47 problems, CI explicitly `continue-on-error`.
- **`removeParticipant`** exists on the store and is called from nowhere. Consequence below.

### Broken or fragile

1. **Client discards all replayed events.** `session-store.ts:applyEvent` early-returns on `eventId <= lastEventId`; `applySnapshot` has already set `lastEventId` to the newest id. `EVENTS` always carries ids ≤ that. Chat and destination changes missed during a disconnect are lost permanently. Server behavior is correct — this is purely a client ordering bug.
2. **No WS heartbeat.** Neither side pings. A half-open TCP connection (device sleeps, carrier NAT drops, tunnel dies) leaves `ConnState` in the map and the participant `online` forever. `presence.ts` can't help: it short-circuits to `offline` only when `connId === null`, and `connId` is only cleared by a `close` event that never fires.
3. **`UNAUTHORIZED` is not fatal on the client.** `ws-client.ts:FATAL_CODES = ['NOT_IN_SESSION','SESSION_NOT_FOUND','INVALID_TOKEN']` — but `handshake.ts:27` sends `UNAUTHORIZED` for a bad token. A stale token produces an infinite reconnect→reject→reconnect loop at 8s intervals with no user-visible error.
4. **Fan-out is O(total connections), not O(session size).** `broadcastToSession` (`handler.ts:47`) iterates the global `connections` map on every single event. With S sessions × P participants each sending 1 loc-update/sec, that is `S·P` events/sec × `S·P` iterations = **O((S·P)²) comparisons per second**. At the documented acceptance bar (1 session × 20 users) it is invisible; at 20 sessions × 10 users it is 40,000 wasted iterations/sec.
5. **`EventBuffer.push` uses `Array.shift()`** — O(n) memmove of up to 1000 elements on every event once the buffer is full, on the hottest path in the system.
6. **Sessions leak participants; participants leak sessions.** `handleLeaveSession` and `handleDisconnect` mark `status='offline'` but never delete the participant. `cleanup()` removes a session when `participants.size === 0` — which now never happens. Every session survives the full 2-hour TTL holding every participant who ever joined.
7. **`PARTICIPANT_JOINED` on every reconnect.** `handshake.ts:76` pushes it unconditionally, so a flaky connection emits a join event per reconnect. Burns event ids and shows spurious "X joined" in any UI that renders them.
8. **`fly.toml` sets `CORS_ORIGIN = "true"`.** `parseCorsOrigin` (`config.ts:110`) returns booleans only for *unset/empty*; the literal string `"true"` becomes a single-element allowlist containing the origin `"true"`. Deploying to Fly with this file blocks every real browser origin. Also `min_machines_running = 0` + `auto_stop_machines` wipes all in-memory sessions on idle — as does Render free-tier spin-down.
9. **`setupWebSocket(server)` runs after `app.listen()`** (`index.ts:22-28`). A connection arriving in that window gets no handler.
10. **`GET /sessions/:sessionId` is unauthenticated** and returns every participant's display name and presence. Session ids are UUIDv4 so it is not trivially enumerable, but it is a real information leak for a location-sharing app, and `POST /sessions/join` has no rate limit against 6-character-code guessing (32⁶ ≈ 10⁹ keyspace, but no cost per attempt).

### Technically strong already — leave alone

`packages/shared` protocol modeling · `config.ts` · `logging.ts` · `ws/voice.ts` · `EventBuffer`'s gap semantics · the CI workflow. None of these need refactoring.

### What prevents it feeling complete

The app's own README promises "**Reconnect-safe** — exponential backoff with event replay (no missed updates)" and that is the one thing that demonstrably does not work. Phase 3 is visible in the protocol docs and half-present in the type system, which reads as abandoned rather than deferred. And the demo dies if the free-tier host sleeps.

---

## 4. Finishing Roadmap

### Phase 0 — Verify baseline

**W0.** Establish and record the current truth. **Priority: do first. Difficulty: Small.**
```bash
npm install && npm run build:shared
npm test                         # expect 73 passed
npm run typecheck -w services/api && npm run typecheck -w apps/mobile
npm run lint -w apps/mobile      # expect 36 errors — record the list
```
Then a two-device manual run: create on device A, join on B, confirm both markers move; kill Wi-Fi on B for 30s; restore. **Record what B has lost.** That observation is the acceptance evidence for W1.
Acceptance: baseline numbers written into `tasks/todo.md`; the reconnect data-loss reproduced by hand.

---

### Phase 1 — Fix correctness

**W1. Fix client-side event replay.** **Priority: P0. Difficulty: Small. Blocks: W6, W15.**
- Files: `apps/mobile/src/state/session-store.ts`, `apps/mobile/src/services/ws-client.ts`.
- Wrong: `applySnapshot` sets `lastEventId = snapshot.latestEventId`, then `applyEvent` rejects the `EVENTS` replay because every replayed id is `<=` it.
- Implementation: split the two concepts. Keep `lastEventId` as *the highest id whose effects have been applied*. In `applySnapshot`, merge participants/destination but leave `lastEventId` untouched; then `EVENTS` (all `> lastEventId`) apply in order and `lastEventId` ends at `toEventId`. Handle the gap-too-large case (no `EVENTS` follows the snapshot) by having the server **always** send `EVENTS`, possibly empty — a 3-line change in `handshake.ts:60` that removes the ambiguity entirely and is preferable to a client-side timer.
- Also add a **gap guard**: if an incoming `EVENT` has `eventId > lastEventId + 1`, the client has missed something — force a resync by closing and reconnecting with the current `lastEventId`.
- Why: the flagship claim in the README is currently false.
- Acceptance: new mobile unit test (W15) — apply snapshot at id 10, then `EVENTS` 5..10 containing a `CHAT_MESSAGE` at id 7; assert the message lands in `chatMessages` exactly once. Plus manual: disconnect B for 30s while A sends 3 chats; on reconnect B sees all 3.

**W2. Add WebSocket heartbeat and dead-connection reaping.** **Priority: P0. Difficulty: Small. Depends: none.**
- Files: `services/api/src/ws/handler.ts`, `services/api/src/config.ts`, `apps/mobile/src/services/ws-client.ts`.
- Wrong: nothing detects a half-open socket; `ConnState` and `status: 'online'` persist indefinitely.
- Implementation: standard `ws` pattern — on `connection`, set `conn.isAlive = true` and `ws.on('pong', () => conn.isAlive = true)`. One `setInterval` at `WS_HEARTBEAT_INTERVAL_MS` (new config var, default 15000) walks `connections`: if `!isAlive`, `ws.terminate()` (fires `close` → existing `handleDisconnect`); else set `isAlive = false` and `ws.ping()`. Clear the interval in the existing `shutdown`. On the client, add a watchdog: if no message of any kind arrives for `2 × interval`, `ws.close()` to trigger the existing reconnect path (RN's `WebSocket` does not surface ping/pong, so a receive-timeout is the right client-side equivalent).
- Why: this is the difference between "presence" and "a status field that lies."
- Acceptance: new `services/api/src/__tests__/heartbeat.test.ts` — open a connection, complete HELLO, stop responding to pings; assert that within `2 × interval` the participant is `offline` and `PARTICIPANT_LEFT` was broadcast.

**W3. Make `UNAUTHORIZED` fatal on the client.** **Priority: P0. Difficulty: Small.**
- File: `apps/mobile/src/services/ws-client.ts` (`FATAL_CODES`).
- Add `'UNAUTHORIZED'`; surface a user-visible "session expired — rejoin" state rather than silently disconnecting.
- Acceptance: with a tampered token in AsyncStorage, the app shows the rejoin prompt within one connect attempt instead of looping.

**W4. Scope fan-out to the session; make the ring buffer O(1).** **Priority: P1. Difficulty: Small. Enables: W14.**
- Files: `services/api/src/ws/handler.ts`, `services/api/src/state/event-buffer.ts`.
- (a) Add `const sessionConnections = new Map<string, Set<ConnState>>()`. Populate on HELLO bind, remove on close/leave. `broadcastToSession` and `getSessionConnections` read from it. Keep the flat `connections` map for `getConnection`.
- (b) Replace `shift()` with a fixed-size circular array plus a head index; `getRange` walks the ring. Keep the existing public API (`push`, `oldestEventId`, `newestEventId`, `getRange`, `size`, `clear`) so `event-buffer.test.ts`'s 7 tests pass unmodified — that is the regression proof.
- Why: turns fan-out from O(all connections) into O(session participants) and removes an O(n) memmove from the hot path. Small, local, low-risk, and directly backs the benchmark in W14.
- Acceptance: `event-buffer.test.ts` passes unchanged; a new test asserts a broadcast in session A does not touch connections in session B (spy on `send`).

**W5. Fix participant/session lifecycle leaks.** **Priority: P1. Difficulty: Small.**
- Files: `services/api/src/ws/leave.ts`, `services/api/src/state/session-store.ts`.
- `handleLeaveSession` should call the already-existing `sessionStore.removeParticipant` after broadcasting `PARTICIPANT_LEFT` (an explicit leave is intentional; a disconnect is not — keep `handleDisconnect` marking `offline` only, so reconnect+replay still works). Add a grace rule in `cleanup()`: remove a session when every participant has `connId === null` and `lastSeenTs` is older than `SESSION_TTL_MS`, in addition to the empty check.
- Why: without this, `cleanup()`'s empty-session branch is dead code and every session holds every past participant for 2 hours.
- Acceptance: test — create, join, both `LEAVE_SESSION`, run `cleanup()`, assert `sessionCount === 0`.

**W6. Stop re-broadcasting `PARTICIPANT_JOINED` on reconnect.** **Priority: P2. Difficulty: Small. Depends: W1.**
- File: `services/api/src/ws/handshake.ts:76`.
- Add `hasJoined: boolean` to `FullParticipantState`, set on first successful HELLO, and gate the push on it.
- Acceptance: `handshake.test.ts` gains a case — reconnect with a valid `lastEventId` produces WELCOME/SNAPSHOT/EVENTS and **no** new `PARTICIPANT_JOINED`.

---

### Phase 2 — Complete Phase 3 (the declared-but-unbuilt product surface)

**W7. Backend safety handlers — SOS, arrival, battery.** **Priority: P0 for completeness. Difficulty: Medium. Depends: W1, W4.**
- New file `services/api/src/ws/safety.ts`; edits to `ws/dispatcher.ts`, `ws/location.ts`, `state/session-store.ts`, `config.ts`.
- `handleRaiseSos(conn, payload)`: read the sender's `participant.lastLocation` **server-side** (spec §5.2 forbids trusting a client position), write `session.sosActive.set(participantId, { note: payload.note ?? null, ts: Date.now() })`, push `SOS_RAISED { participantId, note, lat, lng, ts }` with `lat`/`lng` `null` when unknown (spec §9 Q2), broadcast.
- `handleClearSos(conn)`: delete only the sender's own entry; if it wasn't set, no-op silently. Push `SOS_CLEARED`.
- `handleArrivalPing(conn)`: if `session.destination === null` → `ERROR BAD_MESSAGE`. Else compute haversine distance from `participant.lastLocation`; if `> ARRIVAL_RADIUS_M` (new config var, default 50) → `ERROR NOT_ARRIVED` (the code already exists in `ErrorCode`). Else `session.arrived.add(participantId)`, push `ARRIVAL_PINGED`, broadcast. Idempotent — a second ping for the same destination is a no-op, not an error.
- `handleLocUpdate`: persist `payload.battery`/`payload.charging` onto the participant and include both (defaulting to `null`) in the `LOCATION_UPDATED` data, which the type already requires.
- Add the three `case`s to the dispatcher switch. Put haversine in `services/api/src/utils/geo.ts` — mobile already has one at `apps/mobile/src/utils/geo.ts`; do **not** create a shared package for one function, a 12-line duplicate is cheaper than a new build dependency.
- Per SPEC §9 Q4: SOS **persists** across disconnect.
- Why: already specced, typed, validated, documented, and half-stored. Not finishing it is the single most visible incompleteness in the repo.
- Acceptance: new `__tests__/safety.test.ts` — raise → all participants receive `SOS_RAISED` with server-sourced coords; raise with no known location → `lat/lng: null`; participant B cannot clear A's SOS; SOS appears in `SNAPSHOT.activeSos` **and** the participant row after reconnect; `ARRIVAL_PING` outside 50m → `ERROR NOT_ARRIVED`; inside → `ARRIVAL_PINGED` + `arrived` in snapshot; battery arrives in both `SNAPSHOT` rows and `LOCATION_UPDATED` data. Suite total ≥ 85.

**W8. Mobile safety UI.** **Priority: P1. Difficulty: Medium. Depends: W7.**
- Files: `services/ws-client.ts` (+`sendRaiseSos`, `sendClearSos`, `sendArrivalPing`; extend `sendLocUpdate` with battery), `state/session-store.ts` (`sosActive` map, `arrived` set, `battery`/`charging` on `Participant`, `applyEvent` cases for the three new kinds, and **`applySnapshot` must stop dropping these fields** — its current inline cast omits them), `components/PresenceList.tsx`, `screens/SessionScreen.tsx`.
- Add `expo-battery` (the one new dependency; justify in `ARCHITECTURE.md` per `CLAUDE.md`). Read level+charging on the same cadence as location, foreground-only.
- UI: SOS button with a confirm step (irreversible-feeling action, and it alerts everyone) → strong haptic + red pulsing marker + banner for receivers; low-battery badge at `< 0.15 && !charging`; "I'm here" button enabled only inside 50m, wired to the existing Batch-16 arrival detection so it auto-fires at most once per destination.
- Acceptance: two-device manual — A raises SOS, B gets haptic+banner+focused marker; B force-quits and relaunches, SOS still shown (snapshot path); A clears, B's banner clears.

**W9. Mobile reconnect UX.** **Priority: P2. Difficulty: Small. Depends: W1, W3.**
- Files: `services/ws-client.ts`, `screens/SessionScreen.tsx`.
- Surface three distinguishable states: connected / reconnecting (with attempt count, already tracked via `reconnectCount`) / session-invalid. Today `connected: false` conflates all three.
- Acceptance: airplane-mode toggle shows "Reconnecting…" then recovers; tampered token shows "Session expired."

---

### Phase 3 — Harden what exists

**W10. Rate-limit chat and the join endpoint.** **Priority: P1. Difficulty: Small.**
- Files: `services/api/src/ws/chat.ts`, `services/api/src/http/routes.ts`, `config.ts`.
- Chat: per-participant token bucket (e.g. 5 messages / 5s, new config vars). Over limit → `ERROR RATE_LIMITED` (code already exists, currently emitted nowhere). Do **not** silently drop — location updates silently drop because they are lossy by nature; chat is not.
- Join: in-memory per-IP counter on `POST /sessions/join`, e.g. 20 attempts/minute → 429. No new dependency; a `Map<ip, {count, windowStart}>` swept by the existing cleanup timer is enough at this scale.
- Acceptance: test — 100 chat messages in 1s yields ≤ limit broadcasts plus `RATE_LIMITED` errors, and a second participant's messages are unaffected.

**W11. Close the `GET /sessions/:sessionId` leak.** **Priority: P1. Difficulty: Small.**
- File: `services/api/src/http/routes.ts`.
- Require the participant token (header or query) and 404 without it — matching the WS `HELLO` model, no new auth concept. Keep an unauthenticated `{ exists: true, participantCount }` shape if the join screen needs a preview.
- Acceptance: test — request without a token → 404; with a valid participant token → full body.

**W12. Fix the boot-order race and pick one deploy target.** **Priority: P1. Difficulty: Small.**
- Files: `services/api/src/index.ts`, `fly.toml` / `render.yaml`.
- Move `setupWebSocket(app.server)` **before** `await app.listen(...)`.
- Choose one host and delete the other config. Given in-memory state, the deciding factor is idle behavior: Render free spins down after ~15 min idle and Fly with `min_machines_running = 0` stops — **both destroy every live session**. Recommendation: keep Fly, set `min_machines_running = 1`, and **fix `CORS_ORIGIN = "true"`** — either remove the line (unset → reflect origin, which is what was intended) or set the real origin list. Document in `ARCHITECTURE.md` that session loss on restart is accepted and bounded by the in-memory constraint.
- Acceptance: `fly deploy`, then `curl -H 'Origin: https://example.com' -i https://<app>/health` returns a permissive `access-control-allow-origin`; a session created before a 20-minute idle window still exists after it.

**W13. Clear the mobile lint backlog and make it blocking.** **Priority: P2. Difficulty: Small.**
- 36 errors are almost entirely unused imports/vars (`SCREEN_HEIGHT`, `TextStyle`, `fontFamily`, `spacing`). Fix, then remove `continue-on-error` from the CI step.
- Also drop `react-native-reanimated` if genuinely unused — `tasks/lessons.md` records removing its Babel plugin, but the dependency is still installed. Verify with `grep -rn "reanimated" apps/mobile/src` before removing.
- Acceptance: `npm run lint -w apps/mobile` exits 0; CI step is blocking.

---

### Phase 4 — Testing and measurement

**W14. Add a small, honest WS load benchmark.** **Priority: P1. Difficulty: Medium. Depends: W2, W4.**
- New: `services/api/loadtest/fanout.ts` (~120 lines, plain Node + the existing `ws` dependency — no new packages, no k6, no Artillery).
- Spawns N sessions × M participants, each sending 1 `LOC_UPDATE`/sec for 60s with a 5% per-minute reconnect churn. Timestamps `LOCATION_UPDATED` receipt against send. Prints p50/p95/p99 fan-out latency, events/sec, RSS.
- Run at 1×20 (the documented acceptance bar), 5×10, and 20×10. Commit the table to `docs/CAPACITY.md` **with the machine it was measured on**.
- Wire a smoke-sized run (2 sessions × 5 participants, 10s, assert p99 < 500ms) into CI.
- Why: the difference between "should scale" and a number you can defend — and it validates W4 rather than asserting it.
- Acceptance: `docs/CAPACITY.md` exists with real measurements; CI smoke run passes.

**W15. Add mobile unit tests for the pure logic.** **Priority: P1. Difficulty: Medium. Depends: W1.**
- Add Vitest to `apps/mobile` (already in the monorepo; no new tooling class). Test only the framework-free modules: `state/session-store.ts` (event application, replay, dedup, gap detection — this is where W1's bug lived), `utils/geo.ts`, `utils/routing.ts`, `hooks/useParticipantETAs.ts` logic.
- Do **not** attempt component or map rendering tests. Cost is high, value is low, and the map cannot be meaningfully asserted in CI.
- Acceptance: ≥ 20 mobile tests, `npm test` runs both workspaces, CI green.

---

### Phase 5 — Polish and demo

**W16. Sync docs to code; refresh the README's numbers.** **Priority: P2. Difficulty: Small. Depends: all.**
- README says "44 tests" (actual 73, and higher after W7/W15). `ARCHITECTURE.md:286` says "~50 source files, ~6,500 lines" (actual ~10,800 in-source). The "no missed updates" claim is only true after W1 — keep the claim, ship the fix.
- Append a Phase 3 batch summary to `ARCHITECTURE.md` and the battery-not-an-event / SOS-is-replayable decisions to `DECISIONS.md`, as `CLAUDE.md` requires.
- `docs/ENGINEERING_ROADMAP.md` Epics B/C (Supabase auth, friends, RLS) describe a product this project has decided not to be. Mark them **Deferred — out of scope** at the top rather than leaving them looking like pending work.

**W17. One-command demo path.** **Priority: P2. Difficulty: Small.**
- A `scripts/demo.sh` that builds shared, boots the API, and prints the LAN URL + QR for Expo. Two-device demo should need zero tribal knowledge.

---

## 5. Features Worth Adding

Two. Both use data already flowing; neither adds infrastructure.

**WF1. Spatial voice (SPEC-PHASE3 §5.1 / Batch 21).** Scale each peer's audio gain by map distance using the existing `LOCATION_UPDATED` stream and the existing mesh peer connections. `gain = clamp((500 - d) / (500 - 50), 0, 1)`, ramped over ~150ms, with a proximity toggle defaulting on.
- Why it materially improves the project: the only feature here that makes the *product* feel like something people haven't seen, and technically a genuinely good story — "I already had per-peer connections and a location stream; the feature was a gain curve, not a new subsystem." Zero protocol change, zero server work, zero cost.
- **Blocker, verify first (SPEC §9 Q1):** confirm the pinned `react-native-webrtc@124` exposes per-remote-track output gain on iOS *and* Android. If it does not, **cut this feature** — a native shim is not worth it. Marked **Needs Runtime Verification**: build a dev client and check whether `RTCRtpReceiver` / remote `MediaStreamTrack` exposes a settable volume, or whether `MediaStream`-level volume is the only lever.
- Cost: ~150 lines in `useVoiceChat.ts` if the API exists. **After** W1–W8.

**WF2. Session replay / "trip playback" in the summary screen.** The server already retains up to 1000 ordered events per session. At session end, let the user scrub a timeline that replays participant movement onto the map.
- Why: turns the event-sourcing architecture from an implementation detail into something visible — the strongest possible demonstration that the ordered log is real. Also gives `SessionSummaryScreen.tsx` (already 250 lines) a reason to exist beyond static stats.
- Cost: one new `GET /sessions/:id/events?from=&to=` route (token-gated per W11) + a scrubber component. ~250 lines. **After** the core is finished.

## 6. Things NOT Worth Building

| Idea | Why not |
|---|---|
| **Supabase / Postgres persistence, JWT auth, friends graph, RLS suite** (`ENGINEERING_ROADMAP.md` Epics B–C, WP-201…WP-210) | ~10 tickets that violate the project's own stated hard constraint ("In-memory only. No auth provider"). Doubles the surface area and adds nothing to the real-time story that is the actual differentiator. Mark deferred; do not build. |
| TURN server / SFU for voice | Costs money, breaks the free-tier constraint, and the ≤8-peer mesh is the interesting engineering. |
| Redis for session state | Single-instance by design. Redis here is resume decoration with a real operational cost. |
| Horizontal scaling / sticky sessions / clustering | The measured bottleneck (W14) will not be CPU at this scale. Do not solve a problem you haven't measured. |
| Rewriting `SessionScreen.tsx` (980 lines) into a component tree | It works and is not the source of any listed defect. Split it only if a specific change becomes hard — regression risk on the app's most complex screen exceeds the tidiness win. |
| Background location tracking | Explicit non-goal in `SPEC-PHASE3.md` §4 and a privacy liability. |
| Replacing Zustand / Fastify / `ws` | All fine. No problem to solve. |
| Component-level RN testing infra | High cost, low signal. W15's pure-logic tests catch the bugs that actually occurred. |

---

## 7. Testing Plan

Focus effort where bugs actually occurred in this audit.

| Layer | What | Where | Why here |
|---|---|---|---|
| **Unit — backend** | Ring buffer (exists, 7 tests — keep passing through W4's rewrite), presence transitions (exists), config (exists) | `services/api/src/__tests__/` | Already good. The buffer tests are the regression net for the O(1) rewrite. |
| **Unit — mobile (NEW, W15)** | `session-store.applyEvent`/`applySnapshot`: replay after snapshot, duplicate suppression, gap detection, SOS/arrival/battery event application. `geo.ts`, `routing.ts`. | `apps/mobile/src/**/__tests__/` | **Where the one confirmed production bug lives.** Zero coverage today. |
| **Integration — WS** | Handshake, reconnect replay, chat, leave, voice (exists, 73 tests). **Add:** heartbeat reaping (W2), safety handlers (W7), chat rate limit (W10), cross-session broadcast isolation (W4). | `services/api/src/__tests__/` | The protocol is the product. |
| **Integration — HTTP** | Exists (7 tests). **Add:** token-gated session info (W11), join rate limit (W10). | `http.test.ts` | |
| **E2E smoke** | Boot server, two WS clients, full lifecycle: create → join → loc updates → chat → SOS → disconnect A → 3 events → reconnect A → assert A received exactly the 3 missed events, once each. | new `__tests__/e2e-smoke.test.ts` | Single test that would have caught W1. Highest value per line in the plan. |
| **Performance** | W14 fan-out benchmark; CI smoke at 2×5 asserting p99 < 500ms. | `services/api/loadtest/` | |
| **Not worth testing** | RN component rendering, map behavior, WebRTC media, UI theming. | | Cost >> signal; verify by hand on two devices. |

`voice.test.ts` takes 7.7s of the 8.2s suite — presumably real timers. Worth a look during W7, but not a blocker.

No coverage-percentage chasing. CI already has a pinned floor; that is sufficient.

---

## 8. Performance Validation Plan

| Claim | Source | Verdict | Action |
|---|---|---|---|
| "20 concurrent users in one session, 1 update/sec" | `ARCHITECTURE.md:73` | **Plausible but not validated.** No load test exists. Architecture supports it easily. | W14 measures it. |
| "Reconnect-safe … event replay (no missed updates)" | `README.md` | **Misleading based on the code.** Server-side replay is correct and tested; the mobile client discards every replayed event (`session-store.ts:applyEvent`). The user-visible claim is false. | **W1.** Then keep the claim. |
| "eventId monotonic, no gaps, assignment synchronous" | `ARCHITECTURE.md` §3 | **Directly supported.** `pushEvent` has no `await` between increment and buffer push. | None. |
| "Voice ephemeral, never buffered or replayed" | `DECISIONS.md` | **Directly supported**, 14 tests in `voice.test.ts`. | None. |
| "44 tests" | `README.md` | **Stale** — 73 pass. | W16. |
| "~50 source files, ~6,500 lines" | `ARCHITECTURE.md:286` | **Stale** — ~10,800 in-source lines. | W16. |
| "p99 fanout < 250ms at 20 sessions × 10 participants" | `ENGINEERING_ROADMAP.md:323` | **Currently unsupported** — an unmet acceptance criterion, not a claim. Note `broadcastToSession` is O(all connections), so this target is the one most affected by W4. | W4 then W14; publish real numbers in `docs/CAPACITY.md`. |

**Benchmark (W14), deliberately small:** ~120 lines, plain Node + the existing `ws` dep. N sessions × M participants, 1 loc-update/sec, 60s, 5% reconnect churn. Reports p50/p95/p99 send→receive latency, events/sec, RSS. Three configurations (1×20, 5×10, 20×10). Results + hardware in `docs/CAPACITY.md`. CI runs a 2×5 / 10s smoke asserting p99 < 500ms. **No** k6, Artillery, Grafana, or a load-testing framework.

---

## 9. Deployment / Demo Readiness

### Today

Requires: Node 20, `npm install`, `npm run build:shared` **before** any typecheck, then `npm run dev:api` and `npm run dev:mobile` (Expo). The mobile client resolves the backend from `Constants.expoConfig.hostUri` so a physical device on the same LAN works with no config — a good detail. Prod: `Dockerfile` + `render.yaml` (README) *and* `fly.toml`, both live, one of them (Fly) misconfigured.

### Target

```bash
npm install
npm run build:shared      # required before typecheck resolves @waypoints/shared
cp services/api/.env.example services/api/.env   # every var has a working default
npm run dev:api           # :3000, validates config at boot
npm run dev:mobile        # Expo; scan QR on two devices on the same LAN
```
Env: everything in `config.ts` has a default. Set `CORS_ORIGIN` and `LOG_LEVEL` in prod; nothing else required. No database, no external services.
Hosting: **pick Fly, `min_machines_running = 1`, fix `CORS_ORIGIN`** (W12). Note in the README that a restart clears all sessions — the honest consequence of the in-memory constraint, not a bug to hide.
Demo script: two devices, create → join → both markers live → raise SOS on A → B alerts → kill B's network 30s → restore → B has the chat it missed (the W1 proof).

---

## 10. Final Recommended Scope

### Ship Waypoints With

1. Session create/join by 6-char code + deep link, in-memory, no accounts.
2. Live map with per-participant markers, colors, movement status, follow mode.
3. Real-time location streaming over one WS connection, server-throttled, server-ordered.
4. **Correct reconnect + replay**, end to end, proven by an E2E test and a two-device demo.
5. **Heartbeat-backed presence** (online / stale / offline that cannot lie).
6. Host-controlled destination, per-user routes, distance/ETA, arrival detection, group ETA, destination voting.
7. Session chat with rate limiting.
8. **Phase 3 safety layer:** SOS (durable, replayable, server-sourced location), arrival ping (server-validated radius), battery presence enrichment + low-battery badge.
9. WebRTC mesh voice, STUN-only, ≤8 peers — **plus spatial gain if and only if `react-native-webrtc` supports per-peer output volume** (verify first; cut cleanly otherwise).
10. Session summary with arrival order and stats; optional trip-replay scrubber.
11. Cyberpunk design system as-is.
12. ~100 backend tests + ~20 mobile logic tests, CI green with mobile lint blocking.
13. `docs/CAPACITY.md` with measured fan-out latency and named hardware.
14. One deploy target, correctly configured, with session-loss-on-restart documented.

### Execution Order (Waypoints only)

| # | Task | Why here |
|---|---|---|
| 1 | **W0** Verify baseline, reproduce the reconnect data loss | Never fix what you haven't reproduced. |
| 2 | **W1** Fix client event replay | The one broken headline claim. Small fix. |
| 3 | **W2** WS heartbeat + dead-connection reaping | Makes presence honest. |
| 4 | **W3** `UNAUTHORIZED` fatal on client | 1-line; kills an infinite reconnect loop. |
| 5 | **W4** Session-scoped fan-out + O(1) ring buffer | Small, local; makes W14 meaningful. |
| 6 | **W5** Participant/session lifecycle leaks | Makes `cleanup()` reachable. |
| 7 | **W7** Backend safety handlers (SOS / arrival / battery) | The big completion push. |
| 8 | **W8** Mobile safety UI (`expo-battery`, SOS, arrival, badge) | Makes W7 visible. |
| 9 | **W10** Chat + join rate limiting | Uses the `RATE_LIMITED` code that already exists. |
| 10 | **W11** Token-gate session info | Closes a real leak for a location app. |
| 11 | **W6 / W9 / W12 / W13** Join-event dedup, reconnect UX, boot-order + deploy config, mobile lint | Batch of small hardening. |
| 12 | **W15** Mobile logic tests + E2E smoke | Locks in W1; catches the class of bug that occurred. |
| 13 | **W14** Fan-out benchmark → `docs/CAPACITY.md` | Validates W4; real numbers. |
| 14 | **WF1** Spatial voice — **only after verifying per-peer gain support** | Cut cleanly if the library can't do it. |
| 15 | **WF2** Trip-replay scrubber | Makes the event log visible. Optional. |
| 16 | **W16 / W17** Docs sync, one-command demo | Do last, when the numbers are final. |

Items 1–8 reach *correct and complete*. Items 9–13 reach *defensible*. Items 14–16 are the polish that makes it look intentional rather than expanded.

### Interleaving with StabilityNet

The two projects share no code, no language, and no runtime. See `StabilityNet/docs/FINISHING_PLAN.md` for its own ordering. A combined cadence that keeps both moving without context-thrash:

1. W0 + S0 (both baselines)
2. W1, W2, W3 (cheap Waypoints correctness)
3. S1, S3 (cheap StabilityNet correctness/unblocks)
4. W4, W5 · then S2
5. **W7** (Waypoints big push) · then **S5** (StabilityNet big push)
6. W8 · S6
7. Remaining hardening, tests, benchmarks, polish per each plan's own order.
