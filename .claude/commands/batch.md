---
description: Run a Waypoints "batch" — plan, implement, test, doc, ship
argument-hint: <what to build>
---

Execute a Waypoints work batch for: **$ARGUMENTS**

Follow the repo workflow end to end:

1. **Read** the relevant source of truth first: `docs/ARCHITECTURE.md`, plus `docs/WS-PROTOCOL.md`
   if this touches real-time code, and `docs/PRD.md` for scope. Check `tasks/lessons.md` for prior mistakes.
2. **Plan** — add a checked-off batch section to `tasks/todo.md` describing the steps.
3. **Implement** in small commits' worth of change. Respect the hard constraints in `CLAUDE.md`
   (in-memory only, single instance, no new deps without justification).
4. **Test** — add/extend vitest tests for any backend behavior and run `npm test`. Not done until it passes.
5. **Document** — if the protocol changed, update `docs/WS-PROTOCOL.md` + shared types/validators in the same
   change. Append a batch summary to `docs/ARCHITECTURE.md`; record new decisions in `docs/DECISIONS.md`.
6. **Ship** — commit (`feat|fix|chore|docs:`), push, open a PR against `main` using the PR template.

If any step needs an external account/key/dashboard action, append it to `docs/MANUAL_ACTIONS.md` and stop for confirmation.
