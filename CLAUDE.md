# Waypoints — Agent Instructions

Real-time social location-sharing app. React Native (Expo) client + single Node.js backend
(Fastify HTTP + `ws` WebSocket). In-memory state, TypeScript everywhere. Monorepo via npm workspaces.

## Source of truth

`docs/ARCHITECTURE.md` is the engineering source of truth. When code and this file disagree with
ARCHITECTURE.md, ARCHITECTURE.md wins — or update it in the same change and say so.

Read order before non-trivial work:
1. `docs/ARCHITECTURE.md` — system design, invariants, constraints, phase/batch history
2. `docs/WS-PROTOCOL.md` — WebSocket message shapes (read before touching any real-time code)
3. `docs/PRD.md` — product scope + non-goals
4. `docs/DECISIONS.md` — locked-in decisions and their rationale
5. `tasks/lessons.md` — mistakes already made; don't repeat them
6. `tasks/todo.md` — batch history + remaining manual steps

## Layout

```
packages/shared/   @waypoints/shared — domain types, WS discriminated unions, Zod validators
services/api/      Fastify + ws backend, in-memory session store, vitest tests
apps/mobile/       React Native (Expo SDK 54), Zustand state, cyberpunk UI (src/ui/theme)
docs/              engineering + product docs (source of truth)
tasks/             todo.md (batch log), lessons.md (durable lessons)
```

## Commands

Run from repo root:
```bash
npm install            # all workspaces
npm run build:shared   # compile shared types — do this before typechecking api/mobile
npm run dev:api        # backend, tsx watch
npm run dev:mobile     # expo start
npm test               # vitest (backend) — the gate for backend changes
npm run lint           # eslint all workspaces
npm run format         # prettier
```
Shared types must be built before the api or mobile typecheck resolves `@waypoints/shared`.

## Hard constraints (do not violate without an explicit task saying so)

- **In-memory only.** No Redis, no Postgres/SQLite/Mongo, no external DB. `Map<sessionId, SessionState>`.
- **Single process, single instance.** No clustering, worker threads, Docker-orchestration, or horizontal scaling.
- **No auth provider.** Random token issued at join is the model.
- **No new dependency without justification.** Document any `npm install` in the change + ARCHITECTURE.md.
- **Free-tier friendly.** No paid infra or keyed third-party APIs for MVP core.

Full non-goals + rationale live in `docs/ARCHITECTURE.md` §4–§5.

## Real-time invariants (see ARCHITECTURE.md §3 for the full list)

- `eventId` is server-assigned, monotonic per session, no gaps; assignment is synchronous (no async gap).
- Reconnect: client sends `lastEventId` in `HELLO`; server replies `WELCOME` → `SNAPSHOT` → optional `EVENTS`.
  Buffer gap (client too far behind) → send full `SNAPSHOT`, not `EVENTS`.
- Every WS message is `{ type, payload }`; validate inbound against the Zod schema before processing; invalid → `ERROR`.
- Server stamps its own `ts`; client `ts` is informational only.
- Voice (`VOICE_*`) messages are **ephemeral** — never `EVENT`, never buffered, never replayed. Re-join voice after reconnect. (`docs/DECISIONS.md`)

## Working rules

- **Plan first** for any 3+ step task; track it in `tasks/todo.md` (the repo works in numbered "batches").
- **Tests gate backend changes.** No backend change is done until `npm test` passes. Add tests for new backend behavior.
- **Protocol changes** update `docs/WS-PROTOCOL.md` in the same change, and shared types + Zod validators in `packages/shared`.
- **Persist reasoning to docs, not just chat.** Phase/batch summaries → append to `docs/ARCHITECTURE.md`; new decisions/constraints → `docs/DECISIONS.md`; product scope → `docs/PRD.md` (never change scope without explicit user approval).
- **Manual external steps** (accounts, API keys, env vars, dashboard clicks) → append to `docs/MANUAL_ACTIONS.md` under "Pending Actions" with service, why, exact steps, where the result goes — then stop and confirm before continuing.
- **When corrected**, record the durable rule in `tasks/lessons.md` (date, mistake, rule) so it isn't repeated.

## Quality bar

TypeScript everywhere. Small functions, clear names, no magic constants. Validate all server input; reject bad
messages with structured `ERROR` responses. Match surrounding code style. Prefer RN's built-in `Animated` over
reanimated for simple animations (see lessons.md).

## Skills

The vendored caveman skill pack lives in `.agents/skills/` (pinned in `skills-lock.json`) and is exposed to
Claude Code via the `.claude/skills` → `../.agents/skills` symlink. Available: `caveman` (compressed output),
`caveman-commit`, `caveman-review`, `caveman-compress`, `caveman-stats`, `caveman-help`, `cavecrew`. Update the
pack in `.agents/skills`; the symlink and lock keep it in sync.

## Shipping

Commit + push finished work and open a PR against `main` (see the user's memory). PRs follow
`.github/pull_request_template.md`: what changed, why, how to test, and doc updates for any protocol/API change.
Commit style: `feat|fix|chore|docs: …`.
