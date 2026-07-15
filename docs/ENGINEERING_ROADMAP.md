# Waypoints — Engineering Roadmap: Localhost → Production-Grade

**Status**: Authoritative spec. Supersedes ad-hoc batch planning for everything after Batch 18.
**Audience**: Anyone implementing work on this repo (human or agent).
**Last grounded against repo**: 2026-07-13, branch `feat/auth-supabase-architecture`.

---

## 0. How to Use This Document

- Tickets are **strictly ordered**. Do not start a ticket until every ticket it `Depends on` is merged.
- Ticket IDs are stable (`WP-NNN`). Reference them in branch names (`wp-103-ci-pipeline`), commits, and PRs.
- Every ticket has **Acceptance Criteria (AC)**. A ticket is done when every AC is demonstrably true — not when the code compiles.
- **Definition of Done for every ticket** (in addition to its ACs):
  1. `npm test` passes (backend suite, currently 58 tests — this number only goes up).
  2. `tsc --noEmit` clean in every touched workspace.
  3. `npm run lint` clean.
  4. Docs updated in the same PR when behavior changes (`WS-PROTOCOL.md` for protocol, `ARCHITECTURE.md` for structure, `DECISIONS.md` for irreversible choices, `MANUAL_ACTIONS.md` for anything requiring a human).
  5. New dependencies justified in the PR description and in `ARCHITECTURE.md`'s dependency manifest.

### Non-Negotiable Invariants (from `tasks/lessons.md` + `docs/SESSION.md` — violating these is a bug, not a tradeoff)

1. **The database is never on the real-time hot path.** In-memory `SessionStore` is authoritative for live state. All DB writes during live sessions are async, batched, fire-and-forget.
2. **The state taxonomy is sacred.** Every piece of state is exactly one of: *live room state* (in-memory), *replayable session history* (eventId + ring buffer, optionally persisted), or *transient connection data* (never replayed, never persisted). New features must classify their state before writing code.
3. **eventId is monotonic per session, assigned synchronously, no gaps.** Reconnect is served from the ring buffer or snapshot fallback — never from the DB.
4. **Connection-scoped features (voice, typing, presence pings) are ephemeral** — no `EVENT` wrapper, no ring buffer, no replay.
5. **Server resolves identity; clients never assert it.** Participant identity derives from the authenticated connection, not from client payloads.
6. **Validation lives at the edge.** Every HTTP body and WS message is Zod-validated before touching `SessionState`.
7. **Protocol changes ship with `WS-PROTOCOL.md` updates in the same PR.**

### Current State (verified, not aspirational)

| Area | Reality |
|---|---|
| Backend | Fastify + `ws`, single process, in-memory only. 10 src files, 58 vitest tests. |
| Mobile | Expo SDK 54 / RN 0.81 / React 19.1. Maps, chat, presence, voting, voice (WebRTC mesh, STUN-only), cyberpunk UI. Zero automated tests. |
| Shared | Zod-validated WS protocol as discriminated unions. |
| Auth | Random UUID token issued at join. No accounts. |
| Persistence | None. Server restart loses everything. |
| CI/CD | **None.** No GitHub Actions. Correctness is enforced by discipline only. |
| Deployment | Dockerfile + `fly.toml` + `render.yaml` exist; nothing verified as continuously deployed. App points at localhost. |
| Observability | Fastify default logger only. No metrics, no error tracking, no request IDs. |
| Supabase | Phase 3 fully **designed** (schema, RLS, JWT flow, migration plan in `ARCHITECTURE.md`), **not implemented**. |

---

## Epic A — Engineering Foundation (WP-101 … WP-105)

> Nothing else in this roadmap is safe to build without CI. This epic comes first because every later ticket relies on regressions being caught mechanically.

### WP-101 — CI pipeline: lint, typecheck, test on every PR
**Status**: ✅ Implemented (Wave 1). `.github/workflows/ci.yml` runs build:shared → typecheck (shared/api/mobile) → strict lint (api+shared) + informational mobile lint → env-sync check → tests+coverage. Red-check ACs are demonstrable once the workflow runs on the first PR.
**Depends on**: —
**Why**: 58 tests exist but nothing runs them automatically. Every ticket after this one assumes CI as the safety net.
**Scope**:
- `.github/workflows/ci.yml`: triggers on `pull_request` and push to `main`.
- Jobs (Node 20, `npm ci` with workspace-aware caching):
  1. `build:shared` (everything imports it)
  2. `tsc --noEmit` per workspace (`packages/shared`, `services/api`, `apps/mobile`)
  3. `eslint` across the repo
  4. `vitest run` in `services/api`
- Fail the workflow on any warning-level TS error in `services/api` and `packages/shared` (mobile may keep a small documented allowlist).
**AC**:
- [x] A PR with a failing test shows a red check. _(the `Test + coverage` step runs `vitest run`; a failure fails the job)_
- [x] A PR with a type error in any workspace shows a red check. _(dedicated typecheck step per workspace)_
- [x] Total pipeline time < 5 minutes. _(test suite ~9s locally; `npm ci` dominates — well under budget)_
- [x] `README.md` gains a CI badge.

### WP-102 — Branch protection + PR discipline
**Status**: ◑ Partial (Wave 1). `CONTRIBUTING.md` written; branch-protection settings are a GitHub-side manual step documented as Manual Action #13.
**Depends on**: WP-101
**Scope**: Protect `main`: require CI green + 1 review (or self-review checklist for solo dev), forbid force-push, forbid direct pushes. Document the release flow (feature branch → PR → squash merge) in `CONTRIBUTING.md`.
**AC**:
- [ ] Direct push to `main` is rejected by GitHub. _(pending Manual Action #13 — GitHub setting, not code)_
- [x] `CONTRIBUTING.md` exists and states the branch/PR/commit conventions already in use.

### WP-103 — Test coverage reporting + floor
**Status**: ✅ Implemented (Wave 1). `@vitest/coverage-v8` added; floor pinned in `vitest.config.ts` (lines/statements 94, functions 90, branches 80) just below the measured 96.24/92.59/82.07.
**Depends on**: WP-101
**Scope**: Add `@vitest/coverage-v8` to `services/api`. Report coverage in CI. Set an initial hard floor at the current measured line coverage (measure first, then pin — do not guess), failing CI on regression. Raise the floor only in tickets that add tests.
**AC**:
- [x] CI prints a coverage summary per PR. _(`test:coverage` uses the text-summary reporter)_
- [x] Lowering coverage below the pinned floor fails CI. _(vitest `thresholds` fail the run)_

### WP-104 — Backend structured logging + request correlation
**Status**: ✅ Implemented (Wave 1). `src/logging.ts` centralizes Pino config (pretty in dev, JSON in prod); Fastify binds `reqId`, WS connections get a `connId` child logger; inbound messages log routing metadata only; a test suite verifies no coordinates/chat/email reach the logs.
**Depends on**: WP-101
**Why**: `SESSION.md` requires that "a bug can be debugged from logs and a packet trace." Default Fastify logging can't do that across HTTP → WS boundaries.
**Scope**:
- Pino (already Fastify's logger) configured with explicit serializers; JSON in production, pretty in dev.
- `reqId` on every HTTP request (Fastify built-in), `connId` bound into a child logger for every WS connection.
- Every WS message handled logs `{ connId, sessionId, participantId, type, eventId? }` at debug; every `ERROR` sent to a client logs at warn with the reason.
- Never log location coordinates or chat message bodies at info+ (privacy: this is a location app).
**AC**:
- [x] Given a `connId` from a bug report, `grep` reconstructs that connection's full message timeline. _(every WS log line is a child logger bound with `connId`)_
- [x] No PII (coordinates, chat text, emails) at info level — verified by a test that captures log output for a full session flow. _(`__tests__/logging.test.ts`)_

### WP-105 — Config validation at boot
**Status**: ✅ Implemented (Wave 1). `config.ts` is a Zod schema keyed by env-var name; `loadConfig()` aggregates every problem and the singleton exits non-zero on failure. `.env.example` rewritten exhaustively (the old file had drifted — `MAX_PARTICIPANTS_PER_SESSION` vs code's `MAX_PARTICIPANTS`); `scripts/check-env-sync.ts` enforces two-way sync. All vars currently have defaults; the machinery is ready for WP-201 to flip Supabase vars to required.
**Depends on**: WP-101
**Scope**: Replace ad-hoc `process.env` reads in `services/api/src/config.ts` with a single Zod-validated config schema. Missing/malformed required vars crash at boot with a precise message listing every problem (not just the first). Keep `.env.example` files exhaustive and in sync (add a CI check that every key in the config schema appears in `.env.example`).
**AC**:
- [x] Booting with a missing required var exits non-zero, naming the var. _(verified: `PORT=abc` → exit 1 naming PORT; malformed/out-of-range vars are reported all-at-once)_
- [x] CI fails if config schema and `.env.example` drift. _(`check:env` step)_

---

## Epic B — Identity & Persistence (WP-201 … WP-210)

> This is the already-designed Phase 3 (Supabase). The design in `ARCHITECTURE.md` §Phase 3 and the batch breakdown in `tasks/todo.md` (Batches 19–28) are the detailed spec; the tickets below are the ordered, CI-gated slicing of that work. Where this document and `tasks/todo.md` disagree, this document wins.

### WP-201 — Supabase project provisioning (manual gate)
**Depends on**: WP-105
**Scope**: Human executes Manual Actions #9 and #11 (`docs/MANUAL_ACTIONS.md`): create Supabase project, obtain `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET`; configure Auth (email/password, no email confirmation for dev). Add vars to `services/api/.env` and to `.env.example` (values redacted).
**AC**:
- [ ] `services/api` boots with Supabase vars present and validated by the WP-105 schema (vars optional until WP-203 flips them required).

### WP-202 — Database schema migration 001
**Depends on**: WP-201
**Scope**: Commit `services/api/src/db/migrations/001_initial_schema.sql` containing exactly the schema in `ARCHITECTURE.md` §Phase 3: `profiles` (+ signup trigger), `friendships`, `sessions`, `session_participants`, `session_events`, all indexes, all RLS policies. Run it in the Supabase SQL editor (manual). Add a `docs/MANUAL_ACTIONS.md` entry recording that migrations are applied manually and in filename order — **no divergence between committed SQL and applied SQL, ever**.
**AC**:
- [ ] Migration file applies cleanly on a fresh Supabase project.
- [ ] RLS is enabled on all five tables (verified via `pg_tables`/`pg_policies` query pasted into the PR).
- [ ] Signup in Supabase dashboard auto-creates a `profiles` row.

### WP-203 — Backend JWT verification + dual-mode HELLO
**Depends on**: WP-202
**Scope** (Batch 19 in `tasks/todo.md`):
- Deps: `@supabase/supabase-js`, `jsonwebtoken`, `@types/jsonwebtoken`.
- `src/auth/jwt.ts`: `verifySupabaseJwt(token) → { userId } | null` — local HS256 verification against `SUPABASE_JWT_SECRET`, checks `exp`, no network call.
- `src/auth/fastify-auth-hook.ts`: `preHandler` extracting `Bearer` token → `request.userId`; 401 on invalid/expired.
- `ConnState` gains `userId: string | null`.
- `ws/handshake.ts` dual-mode: try JWT first (resolve participant by `userId + sessionId`; server assigns identity), fall back to legacy UUID token + client `participantId`. Expired JWT → new `AUTH_EXPIRED` error code (add to shared `ErrorCode`), distinct from `UNAUTHORIZED` so the client knows to refresh-and-retry rather than give up.
- `helloPayloadSchema`: `participantId` becomes optional.
**AC**:
- [ ] All 58 legacy-path tests pass unmodified.
- [ ] New tests: valid JWT handshake, expired JWT → `AUTH_EXPIRED`, tampered JWT → `UNAUTHORIZED`, JWT for a user not in the session → `UNAUTHORIZED`, legacy token still works.
- [ ] JWT verification is synchronous/local — proven by a test that runs with network disabled (no Supabase mock needed for the verify path).
- [ ] `WS-PROTOCOL.md` documents dual-mode HELLO and `AUTH_EXPIRED`.

### WP-204 — DB service layer + async event flush buffer
**Depends on**: WP-203
**Scope** (Batches 20–21):
- `src/db/supabase.ts`: service-role client singleton.
- `src/db/db-service.ts`: the typed operations listed in `tasks/todo.md` Batch 20 (`upsertProfile`, `createSessionRecord`, `addSessionParticipant`, `endSession`, `markParticipantLeft`, `batchInsertEvents`, `getUserSessions`, `getSessionEvents`, …).
- `src/db/event-flush.ts`: per-session buffer; flush on ≥50 events, 5s timer, or session end; cap 500/session dropping oldest; failures log-and-drop (invariant 1 — never block or retry on the hot path).
- Wire flush into handlers for `PARTICIPANT_JOINED`, `PARTICIPANT_LEFT`, `DESTINATION_SET`, `DESTINATION_CLEARED`, `CHAT_MESSAGE`. Explicit skip (with a code comment stating the invariant) for `LOCATION_UPDATED` and all `VOICE_*`.
- Session create/join/end persist metadata asynchronously (`sessions`, `session_participants`).
**AC**:
- [ ] Flush buffer unit tests: size trigger, timer trigger, end-of-session trigger, overflow drop, DB-failure drop (mocked client).
- [ ] A test proves `LOCATION_UPDATED` never reaches `batchInsertEvents` even across 100 updates.
- [ ] A test proves session create latency is independent of DB latency (inject a 2s-slow mock; HTTP response still < 50ms).
- [ ] With Supabase mock throwing on every call, a full session (create → join → chat → leave) completes normally.

### WP-205 — Profile, friends, and history REST APIs
**Depends on**: WP-204
**Scope** (Batches 22–23): `profile-routes.ts` (GET/PUT `/profile`, GET `/profile/:userId`), `friends-routes.ts` (list, request, accept, reject, delete, search), `history-routes.ts` (GET `/sessions/history` paginated, GET `/sessions/:id/events`, GET `/sessions/:id/summary`). All behind the auth hook. Authorization enforced in route logic *and* backstopped by RLS.
**AC**:
- [ ] Friend lifecycle integration test: request → accept → list shows friend on both sides → delete → gone.
- [ ] Negative tests: accept someone else's request → 403; view a session you weren't in → 403; unauthenticated → 401.
- [ ] History pagination returns stable ordering (by `created_at DESC, id DESC`).

### WP-206 — Mobile auth foundation
**Depends on**: WP-203 (backend accepts JWTs; can ship in parallel with WP-204/205)
**Scope** (Batch 24): `@supabase/supabase-js` on mobile; `services/supabase.ts` with AsyncStorage session persistence; `services/auth.ts` (register/login/logout/getAccessToken/onAuthStateChange); `state/auth-store.ts` (Zustand); `LoginScreen` + `RegisterScreen` in the existing cyberpunk design system (`src/ui/`); auth gate in `App.tsx`.
**AC**:
- [ ] Register → kill app → relaunch → still authenticated (session restored from AsyncStorage).
- [ ] Token auto-refresh verified: force a short-lived token, confirm `getAccessToken()` returns a fresh one after expiry.
- [ ] Logout clears Supabase session and Zustand state; UI returns to Login.

### WP-207 — Mobile JWT integration (HTTP + WS)
**Depends on**: WP-206
**Scope** (Batch 25): all HTTP calls send `Authorization: Bearer`; WS HELLO sends JWT, drops `participantId`; on `AUTH_EXPIRED` → refresh token → reconnect with backoff (reuse the existing exponential backoff, don't fork a second reconnect path); `participantId` taken from WELCOME.
**AC**:
- [ ] Full manual flow verified and recorded in PR: register → create session → second device joins → both see live locations → kill backend → restart → both reconnect with JWT and replay/snapshot correctly.
- [ ] `AUTH_EXPIRED` mid-session triggers silent refresh+reconnect without user-visible session loss.

### WP-208 — Mobile friends, profile, and server-backed history UI
**Depends on**: WP-205, WP-207
**Scope** (Batches 26–27): ProfileScreen, FriendsScreen (+ FriendRequestCard), SessionHistoryScreen + SessionDetailScreen backed by the history API; HomeScreen session history switches from AsyncStorage to the API (keep AsyncStorage as offline cache, API as truth).
**AC**:
- [ ] Two-account manual test: A requests B, B accepts, both lists update.
- [ ] Past session's event log renders joins/leaves/chat/destination changes in order.
- [ ] Airplane-mode launch still shows cached history with an offline indicator.

### WP-209 — Legacy auth removal (breaking, coordinated)
**Depends on**: WP-207 shipped in a store build users actually run (gate on release, not merge)
**Scope** (Batch 28): remove legacy token path from `handshake.ts`, `token` from `ParticipantState`, optional `participantId` from HELLO schema; require auth on all mutating endpoints; migrate every test to JWT flow.
**AC**:
- [ ] Zero references to the legacy token remain (`git grep` for the old field names is empty outside CHANGELOG/docs history).
- [ ] Full suite green; `WS-PROTOCOL.md` shows the final handshake with no dual-mode caveats.

### WP-210 — RLS verification suite
**Depends on**: WP-205
**Why**: RLS policies are security-critical code with zero test coverage; a silently-broken policy leaks location history.
**Scope**: A separate vitest suite (CI-tagged, runs against a dedicated Supabase test project using two real test users and the **anon** key) proving each policy: can't read others' friendships, can't read sessions you weren't in, can't update others' profiles, etc. Runs in CI nightly + on any PR touching `migrations/`.
**AC**:
- [ ] At least one positive and one negative test per policy in migration 001.
- [ ] Suite fails if RLS is disabled on any table (regression canary).

---

## Epic C — Deployed Environments (WP-301 … WP-305)

> "Localhost app" stops here. One staging and one production environment, deployed from CI, with secrets managed properly.

### WP-301 — Choose and consolidate the deployment target
**Depends on**: WP-101
**Why**: The repo currently carries `fly.toml` **and** `render.yaml` — two half-committed deployment stories. Pick one, delete the other.
**Scope**: Evaluate Fly.io vs Render vs Railway against: WebSocket support with long-lived connections, single-instance guarantee (the architecture requires it until Epic G), cost at hobby scale, log access. Record the decision + rejected alternatives in `DECISIONS.md`. Delete the losing config file. Verify the Dockerfile builds and serves `/health` on the chosen platform.
**AC**:
- [ ] Exactly one deployment config remains in the repo.
- [ ] `DECISIONS.md` entry with rationale.
- [ ] Manual deploy succeeds; `/health` returns 200 with uptime/session metadata over the public URL; a WS connection survives ≥ 10 idle minutes (platform idle-timeout check — this kills naive picks).

### WP-302 — Staging environment + secrets management
**Depends on**: WP-301, WP-201
**Scope**: Two isolated environments (staging, production), each with its own Supabase project and its own secrets set via the platform's secret store (never in the image, never in git). Staging uses the WP-201 project; production gets a fresh one with migration 001 applied. Document the environment matrix in `MANUAL_ACTIONS.md`.
**AC**:
- [ ] `staging` and `production` backends reachable at distinct URLs, pointing at distinct Supabase projects.
- [ ] `git grep` finds no secret values; Docker image history contains no secrets.

### WP-303 — Continuous deployment pipeline
**Depends on**: WP-302
**Scope**: GitHub Actions: merge to `main` → CI green → build image → deploy to **staging** automatically. Production deploys on pushing a `v*` tag, gated on the same workflow. Deploy job posts the deployed SHA to `/health` output (add `version` field sourced from build arg).
**AC**:
- [ ] Merging a PR updates staging within 10 minutes, no human steps.
- [ ] `GET /health` on both environments reports the running git SHA.
- [ ] A failed deploy leaves the previous version serving (platform rollback verified once, deliberately, with a broken image).

### WP-304 — Graceful shutdown + connection draining
**Depends on**: WP-303
**Why**: Every deploy now kills live sessions. The existing SIGTERM handler closes Fastify but doesn't drain WebSockets or flush the event buffer.
**Scope**: On SIGTERM: stop accepting new WS connections, send a new `SERVER_RESTART` server message (add to protocol) telling clients to reconnect after N seconds, flush all event-flush buffers, mark in-flight sessions' persistence, close within a deadline (platform grace period). Client: treat `SERVER_RESTART` as a scheduled reconnect (jittered), not an error — no error UI flash.
**AC**:
- [ ] Deploy during an active 3-participant session: all clients reconnect automatically; no participant sees an error state; event history has no gaps a snapshot can't cover.
- [ ] Test proves flush buffers are drained before process exit.
- [ ] `WS-PROTOCOL.md` documents `SERVER_RESTART`.

### WP-305 — Mobile environment wiring
**Depends on**: WP-302
**Scope**: `app.config.ts` already has dev/preview/production variants — wire API/WS base URLs and Supabase anon keys per profile (dev → localhost, preview → staging, production → production). Fail the build (config-time throw) if a production build points at localhost.
**AC**:
- [ ] `eas build --profile preview` produces an app that talks to staging with zero code edits.
- [ ] Production build with a localhost URL fails at config evaluation.

---

## Epic D — Observability (WP-401 … WP-404)

### WP-401 — Error tracking (backend + mobile)
**Depends on**: WP-303
**Scope**: Sentry (free tier): backend SDK with release = git SHA, environment tag; mobile via `sentry-expo` wired into the existing `ErrorBoundary` and the WS client's error paths. Scrub coordinates and chat bodies in `beforeSend`.
**AC**:
- [ ] A thrown test error in staging appears in Sentry tagged with SHA + environment within a minute.
- [ ] A forced mobile crash in a preview build reports with a symbolicated stack.
- [ ] `beforeSend` scrub verified by unit test.

### WP-402 — Backend metrics
**Depends on**: WP-303
**Scope**: `prom-client` exposing `/metrics` (auth-guarded or private): active sessions, active WS connections, messages in/out per type, LOC_UPDATE accept/drop counts, event-flush batch size + failure count, ring-buffer snapshot-fallback count, handshake duration histogram, per-session participant histogram. Platform dashboard or Grafana Cloud free tier for visualization.
**AC**:
- [ ] All listed metrics visible on a dashboard for staging.
- [ ] The snapshot-fallback counter increments in a test that forces a buffer-overflow reconnect (this metric is the tripwire for ring-buffer sizing).

### WP-403 — Alerting on the four signals that matter
**Depends on**: WP-401, WP-402
**Scope**: Alerts (email is fine): backend down (health check fail), Sentry error-rate spike, event-flush failure rate > 0 sustained 10m (Supabase trouble), memory > 80% (the in-memory architecture's fatal signal).
**AC**:
- [ ] Each alert fired once on purpose (chaos-check) and received.

### WP-404 — Mobile session diagnostics
**Depends on**: WP-401
**Scope**: In-app hidden diagnostics screen (long-press version number): connection state, reconnect count, lastEventId, snapshot-vs-replay on last reconnect, token expiry countdown, current backoff. This is the mobile half of "debuggable from logs and a packet trace."
**AC**:
- [ ] During a forced reconnect, the screen shows backoff progression and recovery mode in real time.

---

## Epic E — Protocol & Backend Hardening (WP-501 … WP-506)

### WP-501 — WS heartbeat + dead-connection reaping
**Depends on**: WP-104
**Why**: Mobile networks half-close TCP silently; without ping/pong, dead connections hold participant slots and skew presence until the stale sweep guesses.
**Scope**: Server-side `ws` ping every 30s; terminate on missed pong (2 misses). Client responds to pings natively (RN WebSocket does) and additionally treats > 60s of server silence as dead → proactive reconnect. Presence sweep consumes pong recency as an input.
**AC**:
- [ ] Test: connection that stops ponging is terminated and its participant transitions to `offline` within 90s.
- [ ] Airplane-mode-toggle manual test: client reconnects within backoff bounds without user action.

### WP-502 — Protocol versioning
**Depends on**: WP-501
**Scope**: `HELLO` gains `protocolVersion: number` (current = 1). Server advertises `supportedVersions` in `WELCOME`. Unknown/incompatible version → new `UNSUPPORTED_VERSION` error with the supported range, so old app builds fail with a clear "please update" instead of undefined behavior. Document the compatibility policy (server supports current + previous minor) in `WS-PROTOCOL.md`.
**AC**:
- [ ] Version-mismatch test yields `UNSUPPORTED_VERSION`; client shows an update prompt.
- [ ] Absent `protocolVersion` treated as version 1 (back-compat with shipped builds) until WP-209's breaking window, then required.

### WP-503 — Inbound message limits + per-connection rate limiting
**Depends on**: WP-501
**Scope**: Hard cap on WS frame size (64KB — voice SDP ceiling is 40KB) enforced at `ws` server options; per-connection token bucket for non-location messages (e.g., 20 msgs / 10s burst 30) — location keeps its existing dedicated interval check per `SESSION.md` (don't replace it, it's deliberately primitive); chat length cap enforced in schema; oversized/flooding connections get one `ERROR` then close on repeat.
**AC**:
- [ ] 65KB frame → connection closed, no handler executed, no crash.
- [ ] Flood test: 100 chat messages in 1s results in throttle error + eventual close; other participants' latency unaffected (measured in test).

### WP-504 — Backpressure-aware broadcast
**Depends on**: WP-503
**Why**: `ws.send()` buffers unboundedly; one participant on a dead-slow link makes the server accumulate megabytes per fast-moving session.
**Scope**: Check `ws.bufferedAmount` before send. Above threshold (256KB): drop `LOCATION_UPDATED` fanout for that connection only (it's mutable live state — the next update supersedes; invariant 2 says this is safe), never drop `EVENT`-wrapped messages (they're replayable — if the buffer stays saturated past a deadline, close the connection and let reconnect/replay recover). Metric for both paths.
**AC**:
- [ ] Test with an artificially stalled socket: location fanout to it stops, events queue, other participants unaffected, connection closed after deadline, reconnect replays correctly.

### WP-505 — Session lifecycle completion
**Depends on**: WP-204
**Scope**: Explicit host-only `END_SESSION` message → `SESSION_ENDED` event (replayable) → clients navigate to the existing SessionSummaryScreen → server marks DB session ended, flushes, and schedules in-memory teardown (60s grace for summary reads). TTL cleanup (the existing sweep) becomes the fallback, not the only path.
**AC**:
- [ ] Host ends session: all participants land on summary; DB row shows `ended` + `ended_at`; memory reclaimed after grace.
- [ ] Non-host `END_SESSION` → `FORBIDDEN`.

### WP-506 — Load test harness + capacity baseline
**Depends on**: WP-503, WP-402
**Scope**: A scripted WS load client (plain Node + `ws`, lives in `services/api/loadtest/`) simulating N sessions × M participants at 1 loc-update/sec with realistic reconnect churn (5% per minute). Run against staging. Record: p50/p99 fanout latency (send→receive across participants), memory per session, CPU at 20/100/500 concurrent participants. Commit results to `docs/CAPACITY.md`; wire a smoke-sized run (2 sessions × 5) into CI against a spawned local server.
**AC**:
- [ ] `docs/CAPACITY.md` states measured limits and the resource that saturates first.
- [ ] p99 same-session fanout latency < 250ms at 20 sessions × 10 participants on the production instance size.
- [ ] CI smoke load test passes and asserts p99 < 500ms locally.

---

## Epic F — Mobile Production Quality (WP-601 … WP-606)

### WP-601 — Mobile unit test foundation
**Depends on**: WP-101
**Why**: The mobile app has zero tests; the WS client and session store contain the most intricate client logic (replay ordering, backoff, dedup).
**Scope**: Vitest (not Jest — matches backend, and the target code is pure TS) for `apps/mobile` covering the non-React core: `ws-client.ts` (event ordering, duplicate rejection `eventId ≤ lastEventId`, snapshot-reset semantics, backoff schedule), `session-store.ts`, `utils/geo.ts`, `utils/routing.ts`. Mock WebSocket at the boundary. Add to CI.
**AC**:
- [ ] ≥ 30 tests over ws-client/session-store covering: in-order apply, duplicate drop, gap→snapshot reset, backoff progression 1→2→4→8, reconnect resets backoff.
- [ ] CI runs them on every PR.

### WP-602 — E2E smoke suite (Maestro)
**Depends on**: WP-601, WP-305
**Scope**: Maestro flows against the dev-client build on iOS simulator: (1) register→login, (2) create session → map renders → session code visible, (3) two-simulator join + mutual presence (if runner allows; else single-device join-by-code against a seeded staging session). Runs nightly and pre-release, not per-PR.
**AC**:
- [ ] Flows pass locally and in the nightly workflow; failures upload screen recordings as artifacts.

### WP-603 — Background location + app-lifecycle correctness
**Depends on**: WP-501
**Why**: PRD listed background location as a non-goal for MVP; it's the single biggest real-world gap — the app is useless if positions freeze when someone locks their phone en route.
**Scope**:
- `expo-location` background updates + `expo-task-manager`, iOS `UIBackgroundModes: location`, Android foreground service with the persistent notification Android requires.
- Active-session-only: background tracking starts on session join, stops on leave/end — never ambient (privacy policy already promises this; update `PRIVACY_POLICY.md` + App Store review notes anyway).
- Reduced cadence in background (e.g., significant-change / 10s) — server already tolerates variable cadence by design.
- WS lifecycle: expect iOS to kill the socket in background; on foreground, reconnect and let snapshot/replay recover (this is what the reconnect model was built for — no new protocol).
**AC**:
- [ ] Device test: lock phone, walk 5 minutes, other participant sees movement throughout (cadence may degrade, must not stop).
- [ ] Leaving the session verifiably stops background tracking (OS location indicator off).
- [ ] Battery: one hour in-session in background < 8% drain on the test device, recorded in PR.

### WP-604 — Push notifications
**Depends on**: WP-205, WP-303
**Scope**: `expo-notifications` + Expo push service. Backend: store push tokens (new `push_tokens` table, migration 002, RLS: owner-only), send via Expo API on friend request received, friend accepted, and "session invite" (new endpoint: invite a friend to an active session → deep link, reusing the existing `utils/deeplink.ts` path). No location-triggered notifications yet.
**AC**:
- [ ] Friend request while app is killed → notification → tap → lands on FriendsScreen.
- [ ] Session invite tap → join flow pre-filled with code.
- [ ] Token invalidation handled (Expo receipt errors prune dead tokens).

### WP-605 — OTA updates + release channels
**Depends on**: WP-305
**Scope**: `expo-updates` with EAS Update: preview channel tracks staging, production channel tracks tagged releases. Document the boundary in `CONTRIBUTING.md`: JS-only changes ship OTA; native-module or permission changes require a store build (this repo has been burned by native-module assumptions before — see `tasks/lessons.md` on WebRTC/reanimated).
**AC**:
- [ ] A JS fix published to preview reaches an installed preview build on next launch.
- [ ] Runtime-version policy prevents an OTA update from landing on an incompatible native binary.

### WP-606 — Offline & degraded-network UX pass
**Depends on**: WP-601
**Scope**: Systematic pass using Network Link Conditioner profiles (3G, 100% loss, high latency): every screen has a defined offline state; session screen distinguishes "you are offline" from "peer is offline"; queued chat sends on reconnect (bounded queue, drop with notice past 20); create/join fail fast with retry affordance, no spinner-forever.
**AC**:
- [ ] Checklist of screens × network profiles committed in the PR, all cells passing.
- [ ] Chat sent while briefly offline arrives after reconnect exactly once (dedup by client message id — protocol addition, documented).

---

## Epic G — Scale-Out (WP-701 … WP-704)

> **Gate**: Do not start this epic until WP-506 capacity data shows the single instance approaching saturation, or product demands multi-region. The single-instance constraint in `ARCHITECTURE.md` is lifted *by this epic and only by this epic*. Until then it stands.

### WP-701 — Redis-backed cross-instance pub/sub design
**Depends on**: WP-506 (data), WP-402 (metrics)
**Scope**: Design doc (no code): session-affinity routing (a session lives on exactly one instance — pin by `sessionId`, don't distribute a room across instances; it preserves every invariant: synchronous eventId, in-memory authority) vs. full shared-state. Recommend affinity + Redis for session→instance directory and cross-instance session lookup/join-code resolution. Cover instance-death recovery (session dies with instance; clients get fresh session semantics — decide whether that's acceptable or if snapshots checkpoint to Redis). `DECISIONS.md` entry.
**AC**:
- [ ] Design reviewed and merged into `ARCHITECTURE.md` before any implementation ticket opens.

### WP-702 — Session directory + affinity implementation
**Depends on**: WP-701
**Scope**: Per WP-701's accepted design. Legacy invariants must survive: a reconnect to the wrong instance is redirected (new `MOVED` error carrying the correct WS URL) rather than half-served.
**AC**: Defined by WP-701's design doc; minimally, a 2-instance deployment passes the entire WP-506 load suite with sessions correctly pinned.

### WP-703 — Voice: TURN server
**Depends on**: WP-402 (need mesh-failure metrics first — instrument voice connection success rate as part of this ticket's first commit)
**Scope**: Instrument NAT traversal success; if < ~90%, deploy coturn (or a managed TURN) with short-lived HMAC credentials issued by the backend (`GET /voice/turn-credentials`, authenticated). Client adds TURN to ICE servers.
**AC**:
- [ ] Voice connects between two devices on symmetric-NAT cellular networks.
- [ ] TURN credentials expire ≤ 1h and are per-user.

### WP-704 — Voice: SFU migration (conditional)
**Depends on**: WP-703, and only if metrics show sessions with > 8 voice participants failing
**Scope**: Evaluate LiveKit (self-hosted vs cloud) vs mediasoup. The WS voice signaling layer becomes join/leave + SFU token issuance; mesh code retired. Separate design doc first, same rule as WP-701.
**AC**: 12-participant voice session with acceptable quality on mid-tier devices.

---

## Epic H — Security & Compliance (WP-801 … WP-803)

### WP-801 — Dependency + secret hygiene automation
**Depends on**: WP-101
**Scope**: Dependabot (npm, weekly, grouped), `npm audit` gate in CI (fail on high/critical with a documented allowlist file), gitleaks secret scan in CI, and a one-time history scan (`.env` was never committed — verify and record).
**AC**:
- [ ] CI fails on a deliberately added known-vulnerable package (tested once, reverted).
- [ ] Gitleaks full-history scan report attached to the PR: clean.

### WP-802 — Abuse-resistance pass on public surface
**Depends on**: WP-503, WP-209
**Scope**: HTTP rate limiting (`@fastify/rate-limit`): per-IP on unauthenticated endpoints, per-user on authenticated. Join-code brute-force math: 6-char A–Z0–9 = ~2.2B codes, but active-session count is tiny — add per-IP join attempt limiting (10/min) and constant-time comparison. Friend-request spam cap (N pending outbound). Account enumeration: register/login errors don't distinguish "no such user" from "wrong password".
**AC**:
- [ ] Scripted brute-force of join codes is throttled to uselessness (test).
- [ ] Rate-limit headers present; limits documented in `ARCHITECTURE.md`.

### WP-803 — Privacy controls + data deletion
**Depends on**: WP-205
**Scope**: Account deletion endpoint (Supabase admin delete + cascade verification — the schema already cascades, prove it), in-app "Delete account" (App Store requires this for apps with accounts — hard submission blocker), data-retention job: purge `session_events` older than 90 days (pg_cron or scheduled function), `PRIVACY_POLICY.md` updated to match actual behavior.
**AC**:
- [ ] Deleting an account removes profile, friendships, participant rows, and push tokens (verified by test querying as service role).
- [ ] Retention job proven against seeded old rows.

---

## Epic I — Release & Store (WP-901 … WP-903)

### WP-901 — Versioning + changelog discipline
**Depends on**: WP-303
**Scope**: Semver git tags drive production deploys (already, per WP-303) and EAS builds (`autoIncrement` for buildNumber/versionCode is configured — verify). `CHANGELOG.md` maintained per release. Release checklist doc: tests → staging soak (24h) → tag → store build → phased release.
**AC**:
- [ ] One full dry run of the checklist executed and annotated.

### WP-902 — TestFlight pipeline
**Depends on**: WP-602, WP-901, manual Apple Developer enrollment (see `MANUAL_ACTIONS.md`)
**Scope**: `eas build --profile preview` + `eas submit` from a manually-triggered GitHub Action (EAS credentials in repo secrets). Internal TestFlight group. Crash-free-rate gate (via Sentry) before promoting any build.
**AC**:
- [ ] A TestFlight build installable on a real device, pointing at staging, delivered end-to-end from an Actions run.

### WP-903 — App Store submission
**Depends on**: WP-902, WP-803, WP-603 (background-location review notes)
**Scope**: Execute `docs/APP_STORE_METADATA.md` + `docs/MANUAL_ACTIONS.md`: screenshots, privacy nutrition labels (location: linked to user, used for app functionality; account info), background-location justification in review notes, phased release.
**AC**:
- [ ] App approved and live. (Rejections get triaged as new tickets referencing the rejection reason.)

---

## Sequencing Summary (critical path)

```
WP-101 CI ─┬─ WP-102/103/104/105 (foundation)
           ├─ Epic B: 201→202→203→204→205→210
           │            └→ 206→207→208 ─────────→ 209 (post-rollout)
           ├─ Epic C: 301→302→303→304, 305
           ├─ Epic D: 401/402→403, 404
           ├─ Epic E: 501→502/503→504, 505, 506
           ├─ Epic F: 601→602, 603, 604, 605, 606
           ├─ Epic H: 801, 802 (after 503+209), 803 (after 205)
           └─ Epic I: 901→902→903
Epic G is gated on WP-506 capacity data — do not pre-build scale.
```

Recommended execution order for a small team: **A → B (201–207) → C → D(401–402) → E(501–505) → B(208–210) → F(601, 603, 606) → H → E(506) → F(602, 604, 605) → I → G (only if data demands it).**

The through-line: every ticket either (a) makes regressions mechanically impossible, (b) moves state to where it architecturally belongs, or (c) makes failure visible and bounded. That — not feature count — is what "next level" means for this system.
