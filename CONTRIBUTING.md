# Contributing to Waypoints

This document captures the branch, PR, and commit conventions already in use, plus
the local checks that CI enforces. It exists so the workflow is written down rather
than tribal (roadmap ticket WP-102).

## Repository layout

Waypoints is an npm-workspaces monorepo:

| Workspace          | What it is                                              |
| ------------------ | ------------------------------------------------------- |
| `packages/shared`  | Zod-validated WS protocol + shared TypeScript types.    |
| `services/api`     | Fastify + `ws` backend (single process, in-memory).     |
| `apps/mobile`      | Expo / React Native app.                                |

Everything imports `@waypoints/shared` from its built `dist/`, so **build shared first**
after changing it: `npm run build:shared`.

## Branch & PR flow

`main` is protected (see [`docs/MANUAL_ACTIONS.md`](docs/MANUAL_ACTIONS.md) → "Configure
branch protection"). Do not push to it directly.

1. Branch off `main`. Name the branch after the roadmap ticket when there is one:
   `wp-104-structured-logging`, or a conventional prefix otherwise: `feat/…`, `fix/…`,
   `docs/…`, `chore/…`.
2. Make your change in small, reviewable commits.
3. Open a PR into `main`. Fill in the PR template (what / why / how to test / checklist).
4. CI must be green (see below). Solo changes still go through a PR so CI runs and there
   is a review record — self-review against the checklist counts.
5. **Squash merge.** Keep the squash commit message in the Conventional Commits style
   (see below). Delete the branch after merge. No force-pushes to `main`.

## Commit messages

Conventional Commits, matching existing history:

```
<type>: <imperative summary>

<optional body — the "why", not the "what">
```

Types in use: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`. Examples from history:

- `feat: voice chat MVP — WebRTC signaling, backend handlers, mobile UI`
- `fix: remove react-native-reanimated babel plugin to fix WorkletsBabelPluginError`

## What CI checks (`.github/workflows/ci.yml`)

CI runs on every PR and on pushes to `main`. Reproduce it locally before pushing:

```bash
npm ci
npm run build:shared

npm run typecheck -w packages/shared
npm run typecheck -w services/api
npm run typecheck -w apps/mobile

npx eslint services/api/src packages/shared/src --ext .ts   # strict: must be clean
npm run lint -w apps/mobile                                  # informational (see below)

npm run check:env -w services/api                            # config schema ↔ .env.example
npm run test:coverage -w services/api                        # tests + coverage floor
```

### Definition of Done for a change

- All typechecks pass; `services/api` and `packages/shared` lint clean.
- `services/api` tests pass and coverage stays at or above the pinned floor
  (`services/api/vitest.config.ts`). Adding backend behavior means adding tests.
- Docs updated in the same PR when behavior changes: `docs/WS-PROTOCOL.md` (protocol),
  `docs/ARCHITECTURE.md` (structure), `docs/DECISIONS.md` (irreversible choices),
  `docs/MANUAL_ACTIONS.md` (anything needing a human).
- New dependencies justified in the PR description.

### Lint: strict vs. informational

`packages/shared` and `services/api` are held to a **zero-lint-error** bar and block CI.

`apps/mobile` currently carries a pre-existing lint backlog, so its lint step runs
**non-blocking** (informational) in CI. This is a documented, temporary allowlist —
new mobile code should still be lint-clean, and a dedicated cleanup ticket will remove
the allowance once the backlog is cleared.

## Environment configuration

Backend config is validated at boot by a Zod schema in `services/api/src/config.ts`.
Every variable it reads is documented in `services/api/.env.example`. If you add or
remove a variable, update **both** — CI's `check:env` step fails on drift. Never commit
a real `.env` (it is gitignored).
