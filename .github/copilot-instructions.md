# Waypoints Copilot Instructions

You are a coding agent working in this repository.

## Read Order (always do this first)
1) docs/PRD.md
2) docs/ARCHITECTURE.md
3) docs/WS-PROTOCOL.md
4) tasks/lessons.md
5) tasks/todo.md

## Operating Rules
- For any non-trivial task (3+ steps): write a plan first in tasks/todo.md.
- Work in small batches. After each batch: summarize changes + update tasks/todo.md checkboxes.
- Do not invent requirements. If PRD is unclear, propose a decision in the PR description and implement the simplest option.
- Keep MVP free-tier friendly: single backend instance, in-memory session state. Do not add Redis unless a task explicitly says so.
- Do not add new dependencies unless necessary; justify them.
- Every backend change needs tests (unit or integration). No “done” without tests passing.

## Persistence Rules (Required)

- Any Phase summary (Phase 0, Phase 1, etc.) must be persisted to repo docs before continuing.
- Do not leave major reasoning only in chat.

Where to persist:
- Phase summaries and implementation plans -> append to docs/ARCHITECTURE.md under clearly titled sections.
- Protocol changes -> update docs/WS-PROTOCOL.md in the same batch/PR.
- Product scope changes -> update docs/PRD.md (but do not change scope without explicit user approval).
- Manual external steps -> append to docs/MANUAL_ACTIONS.md under "Pending Actions".
- New decisions/constraints -> update docs/DECISIONS.md.

After persisting, summarize what was written and which file(s) changed.

## Manual Steps Protocol

If any task requires:
- External account creation
- API key generation
- Environment variables
- Platform UI interaction

You must:
1) Append the request to docs/MANUAL_ACTIONS.md under "Pending Actions"
2) Clearly describe:
   - What service
   - Why it is needed
   - Exact steps to complete
   - Where the result should be placed (.env, dashboard, etc.)
3) Stop and wait for confirmation before continuing.

## Quality Bar
- TypeScript everywhere.
- Clear naming, small functions, no magic constants.
- Validate input on server. Reject bad messages with ERROR responses.
- Handle reconnects correctly using lastEventId (see WS-PROTOCOL).

## Commands
- Backend (when created): `cd services/api`
  - install: `npm i`
  - dev: `npm run dev`
  - test: `npm test`
  - lint: `npm run lint`
- Mobile (when created): `cd apps/mobile`
  - install: `npm i`
  - start: `npm run start`

## Deliverables for each PR
- What changed + why
- How to run it
- Tests added/updated
- Any protocol or schema updates documented in docs/WS-PROTOCOL.md

## Self-Improvement Loop
When the user corrects you or asks for a behavior change, append a new entry to tasks/lessons.md:
- Date
- Mistake
- Rule to prevent repetition