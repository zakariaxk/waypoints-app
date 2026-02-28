# Todo

## Current Plan
- [x] Write repo scaffold (folders + configs) — Batch 1
- [x] Create backend skeleton (Fastify + ws) and health endpoint — Batch 2
- [x] Implement shared types + validators (packages/shared) — Batch 2
- [x] Implement session create/join (in-memory) — Batch 2
- [x] Implement WS handshake (HELLO/WELCOME/SNAPSHOT) — Batch 3
- [x] Implement location updates (LOC_UPDATE -> LOCATION_UPDATED) — Batch 3
- [x] Implement presence states (online/stale/offline) — Batch 3
- [x] Implement reconnect replay (eventBuffer + EVENTS) — Batch 4
- [x] Backend tests (event buffer, HTTP, WS handshake, presence, reconnect) — Batch 4
- [x] Mobile app skeleton + permissions + map screen — Batch 5
- [x] Mobile WS client + lastEventId + map updates — Batch 5
- [ ] Documentation cleanup + demo video instructions — Batch 6

## Done
- [x] Phase 0: MVP Context Summary (persisted to ARCHITECTURE.md)
- [x] Phase 1: System Design Plan (persisted to ARCHITECTURE.md)
- [x] Batch 1: Monorepo scaffold — root configs, packages/shared, services/api, apps/mobile
- [x] Batch 2: Shared types/validators + backend HTTP routes + session store
- [x] Batch 3: WS handler, handshake, location updates, destination, presence
- [x] Batch 4: Reconnect replay + 27 backend tests (all passing)
- [x] Batch 5: Mobile app — HomeScreen, SessionScreen, WS client, location service, zustand store