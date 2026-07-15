# Lessons

Durable engineering lessons for agents working in this repo. When corrected, append a dated entry
(mistake + rule) so it isn't repeated. See `CLAUDE.md` for the full workflow.

## Rules to avoid repeated mistakes
- Always read docs/PRD.md + docs/WS-PROTOCOL.md before implementing real-time logic.
- Never mark a task done without running tests or providing a manual verification checklist.
- Don’t add new libraries unless required; justify and document.
- When protocol changes, update docs/WS-PROTOCOL.md in the same PR.

### 2026-02-28 — react-native-reanimated babel plugin crash
- **Mistake**: Added `react-native-reanimated/plugin` to babel.config.js for simple scale/translate animations. Reanimated 4.x's Worklets babel plugin crashes with `WorkletsBabelPluginError: Cannot set properties of undefined (setting 'workletNumber')` on Expo SDK 54.
- **Rule**: Prefer React Native's built-in `Animated` API for simple animations (scale, translate, opacity). Only reach for reanimated when you need gesture-driven or layout-based animations. If you do use reanimated, verify the babel plugin actually works before committing.

### 2026-02-28 — Voice chat ephemeral events
- **Decision**: VOICE_* messages must NOT be emitted as type EVENT, must NOT be stored in the event ring buffer, and must NOT be replayed on reconnect.
- **Rule**: Any new real-time feature that is inherently connection-scoped (voice, video, typing indicators) should be ephemeral and use direct message types instead of the EVENT wrapper. Clients must re-establish state after reconnect.
- **Rule**: `react-native-webrtc` requires native modules → EAS dev client build. Document in MANUAL_ACTIONS.md and don't assume Expo Go works.

### 2026-03-01 — Supabase persistence boundaries
- **Decision**: Live session state (locations, presence, voice, ring buffer, rate limits) stays in-memory. Supabase handles auth, profiles, friends, session metadata, and meaningful event history only.
- **Rule**: Never put Supabase on the real-time hot path. All DB writes during live sessions must be async fire-and-forget. In-memory state is always authoritative.
- **Rule**: When adding persistence for a new feature, classify it: real-time (→ in-memory) or historical/relational (→ Supabase). Never blur these boundaries.
### 2026-07-15 — Reliable CI needs deterministic WS test teardown (Epic A / WP-101)
- **Mistake 1 (teardown hang)**: The WS integration tests call `setupWebSocket(app.server)` but only `await app.close()` in teardown. Fastify closes the HTTP server, but open WebSocket sockets keep it alive until the OS times them out (~80s hangs under load). **Rule**: in teardown, terminate `wss.clients` and `wss.close()` *before* `app.close()`.
- **Mistake 2 (dropped-message race)**: Registering a `ws.once('message')` / `collectMessages` listener *after* the action that triggers a server broadcast drops the event (EventEmitter doesn't buffer), hanging the test until timeout. **Rule**: attach the receiver for an expected broadcast *before* performing the action that causes it.
- **Rule**: A flaky test defeats the entire purpose of CI. Treat intermittent WS-timing failures as real bugs in the test's synchronization, not as noise to retry away.
