---
description: Verify WS protocol code, shared types, validators, and docs are in sync
---

Audit that the WebSocket protocol is internally consistent across the codebase. Do not change product
behavior — only report drift and fix genuine mismatches.

Check that these four stay in agreement:
1. `docs/WS-PROTOCOL.md` — documented message shapes (client→server, server→client events, errors, voice).
2. `packages/shared` — the discriminated-union TS types and the Zod validators for inbound messages.
3. `services/api/src/ws/*` — dispatcher routing + handlers actually implement every documented type.
4. `apps/mobile/src/services/ws-client.ts` — client sends/handles the same set.

Verify the invariants in `CLAUDE.md` / `docs/ARCHITECTURE.md §3` hold in code:
- `eventId` monotonic, synchronous assignment, no gaps.
- Reconnect replay: `HELLO(lastEventId)` → `WELCOME` → `SNAPSHOT` → optional `EVENTS`; buffer gap falls back to `SNAPSHOT`.
- Every inbound message validated before processing; invalid → `ERROR`.
- `VOICE_*` messages are ephemeral — never emitted as `EVENT`, never buffered, never replayed.

Report each mismatch with file:line. Then run `npm run build:shared && npm test`.
