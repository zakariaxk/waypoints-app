# Todo

## Goal: App Store Ready

### Completed (All Code Work)
- [x] Monorepo scaffold, shared types, backend HTTP+WS, session store — Batches 1-4
- [x] 44 backend tests passing — Batches 4, 7, 9
- [x] Mobile app: HomeScreen, SessionScreen, live map, chat, presence — Batches 5, 7
- [x] CORS, host controls, persistence, backoff, ETA, error boundary — Batch 9

### Batch 10: Build Infrastructure ✅
- [x] Convert app.json → app.config.ts (dynamic, env-driven)
- [x] Create eas.json (development, preview, production profiles)
- [x] Create metro.config.js (monorepo symlink resolution)
- [x] Create babel.config.js (Expo preset)
- [x] Add bundle identifiers (ios.bundleIdentifier, android.package)
- [x] Add version management (buildNumber, versionCode)
- [x] Install expo-dev-client + expo-splash-screen + expo-haptics + expo-status-bar + expo-constants

### Batch 11: App Icon + Splash Screen ✅
- [x] Generate app icon (1024x1024 PNG via sharp)
- [x] Configure splash screen (branded indigo background)
- [x] Add adaptive icon for Android
- [x] Generate favicon (48x48)

### Batch 12: UI Polish + Quality ✅
- [x] Fix hardcoded colors in DestinationPanel/SessionScreen → use theme
- [x] Fix map initial region → use user's location
- [x] Add HTTP fetch timeouts (10s via AbortController)
- [x] Add expo-status-bar in App.tsx
- [x] Add theme colors (destinationBg, destinationBorder, destinationText, danger)
- [x] Android safe area padding

### Batch 13: Production Deployment ✅
- [x] Create multi-stage Dockerfile
- [x] Create fly.toml for Fly.io
- [x] Create .dockerignore
- [x] Backend compiles + starts from dist/ in production mode

### Batch 14: App Store Assets + Metadata ✅
- [x] Write privacy policy (PRIVACY_POLICY.md)
- [x] App Store description, keywords, category, age rating (APP_STORE_METADATA.md)
- [x] Screenshot guide + review notes
- [x] Manual actions guide (MANUAL_ACTIONS.md) — 6 steps to submission

### Batch 15: Final Testing + Submission Prep ✅
- [x] Build shared types + API compiles clean
- [x] All 44 backend tests passing
- [x] README updated with deployment instructions + App Store checklist
- [x] All docs updated (ARCHITECTURE, WS-PROTOCOL, MANUAL_ACTIONS, DECISIONS)
- [x] Git commit + push

### Batch 16: Enhanced Session Features ✅
- [x] Per-user route colors — unique color palette for each participant's route + markers
- [x] Arrival detection + status badge — participants within 50m show ✓ Arrived, green marker
- [x] Movement status indicator — 🚗 Driving / 🚶 Walking / 📍 Stationary from speed data
- [x] Enhanced live ETA + distance — OSRM distance shown alongside ETA in PresenceList + FriendSheet
- [x] Follow mode toggle — track selected user's camera, disable on manual pan
- [x] Graceful disconnect handling — faded markers for offline (opacity 0.4)
- [x] Group ETA summary bar — fastest/average/longest ETA above tab bar
- [x] Session summary screen — post-session stats with arrival order, duration, distances
- [x] Destination voting — non-hosts propose via long-press, host accepts proposals
- [x] Map mode toggle (standard/satellite/hybrid) — already done in previous batch

### Batch 17: Cyberpunk UI Overhaul ✅
Dependencies added: expo-linear-gradient, react-native-reanimated, react-native-gesture-handler, expo-blur, expo-font, @expo-google-fonts/rajdhani, @expo-google-fonts/orbitron

#### Foundation (tokens + theme + components)
- [x] Install new dependencies
- [x] Create `src/ui/theme/tokens.ts` — full cyberpunk palette + gradients + typography
- [x] Create `src/ui/theme/theme.tsx` — ThemeProvider with dark/light/system + font loading
- [x] Create `src/ui/theme/glowStyles.ts` — reusable glow shadow helpers
- [x] Create `src/ui/components/NeonText.tsx` — typography with Rajdhani/Orbitron
- [x] Create `src/ui/components/NeonButton.tsx` — gradient + glow + haptics
- [x] Create `src/ui/components/HudCard.tsx` — translucent panel + neon border
- [x] Create `src/ui/components/Chip.tsx` — neon pill variants
- [x] Create `src/ui/components/NeonDivider.tsx` — gradient separator
- [x] Create `src/ui/components/BottomSheetPanel.tsx` — reanimated bottom sheet

#### Apply to all screens
- [x] Refactor App.tsx (gradient background, font loading, new ThemeProvider)
- [x] Refactor HomeScreen (cyberpunk redesign)
- [x] Refactor SessionScreen (HUD header, tab bar)
- [x] Refactor MapSection (cyberpunk controls, fix satellite toggle)
- [x] Refactor PresenceList (HUD rows)
- [x] Refactor ChatPanel (cyberpunk bubbles + robust keyboard fix)
- [x] Refactor FriendSheet (cyberpunk panel styles)
- [x] Refactor DestinationPanel, GroupETASummary, DestinationVoting
- [x] Refactor SessionSummaryScreen, SessionHistory, ErrorBoundary

#### Documentation + cleanup
- [x] Delete old theme files (src/utils/theme.ts, src/contexts/ThemeContext.tsx)
- [x] Migrate all component imports to src/ui/theme
- [x] Create docs/UI_STYLEGUIDE.md
- [x] Update docs/PRD.md with Cyberpunk UI section
- [x] TypeScript passes zero errors (except pre-existing ws-client cast, now fixed)
- [x] Fix satellite toggle bug (removed invalid 'mutedStandard' map type)
- [x] Fix chat keyboard overlap (removed double KeyboardAvoidingView, dynamic offset)
- [x] Git commit

### Batch 18: Voice Chat (Phase 2) — Feature Branch `feature/voice-chat`

#### Phase A0 — Signaling + Voice Presence (no audio)
- [x] Shared: Add VOICE_* TS types + Zod schemas in packages/shared
- [x] Backend: Add voiceMembers Set to session state
- [x] Backend: Create services/api/src/ws/voice.ts (VOICE_JOIN/LEAVE/SIGNAL handlers)
- [x] Backend: Wire VOICE_* into dispatcher.ts
- [x] Backend: Cleanup voiceMembers on leave/disconnect
- [x] Backend: Add services/api/src/__tests__/voice.test.ts (all required tests)
- [x] Docs: Update WS-PROTOCOL.md with VOICE_* messages + ephemeral rules
- [x] Docs: Add decision to DECISIONS.md (voice events not replayed)
- [x] Docs: Add "Phase 2: Voice Chat" to PRD.md (don't change MVP non-goals)
- [x] Docs: Append voice summary to ARCHITECTURE.md
- [x] Mobile A0: Extend ws-client for VOICE_SIGNAL + VOICE_STATE
- [x] Mobile A0: Create services/voice.ts (joinVoice/leaveVoice/sendSignal)
- [x] Mobile A0: Add "Voice (beta)" toggle + status indicator in SessionScreen

#### Phase A1 — Mobile WebRTC Audio Integration + UI
- [x] Mobile: Add react-native-webrtc dependency (document justification)
- [x] Mobile: Create hooks/useVoiceChat.ts (WebRTC peer connections, mic, PTT)
- [x] Mobile: Add Voice UI components (Join/Leave, Mute, PTT, peer count)
- [x] Mobile: Handle mic permissions (platform-correct)
- [x] Docs: Append MANUAL_ACTIONS.md if EAS dev client / native module needed
- [x] Run tests, verify passing (58/58 tests pass)

### Batch 19 (Phase 3) — P3-01 · Protocol contract (ZAK-5)
Contract-only, no behavior. Blocks all other Phase 3 tickets (02–09).
- [x] Shared types: RAISE_SOS/CLEAR_SOS/ARRIVAL_PING client msgs; LOC_UPDATE += battery/charging
- [x] Shared types: SOS_RAISED/SOS_CLEARED/ARRIVAL_PINGED events; LOCATION_UPDATED += battery/charging
- [x] Shared types: SNAPSHOT participants += battery/charging/arrived/sos, + activeSos[]; ErrorCode += NOT_ARRIVED
- [x] State types: ParticipantState += battery/charging; SessionState += sosActive Map, arrived Set
- [x] Zod validators + discriminated union for new inbound; battery range 0..1, note ≤140 enforced
- [x] Docs: WS-PROTOCOL.md tables; DECISIONS.md (SOS-replayable, battery-not-an-event, NOT_ARRIVED)
- [x] `npm run build:shared` + `npm run lint` clean; Zod accept/reject verified
- Downstream: backend (02–05) will fill required SessionState/ParticipantState fields; api typecheck stays red until then (expected, contract-first).

## Remaining Manual Steps (see docs/MANUAL_ACTIONS.md)
- [ ] Apple Developer account enrollment ($99/yr)
- [ ] EAS project init (`eas login && eas init`)
- [ ] Deploy backend to Fly.io (`fly deploy`)
- [ ] Host privacy policy (GitHub Pages or similar)
- [ ] App Store Connect setup (create app, metadata, screenshots)
- [ ] EAS build: preview → TestFlight → production
- [ ] Submit for App Store review
- [ ] Create Supabase project (get URL, keys, JWT secret)
- [ ] Run database migrations in Supabase SQL Editor
- [ ] Configure Supabase Auth settings
- [ ] Update Fly.io environment variables with Supabase credentials

---

## Phase 3: Supabase Architecture Upgrade

### MANUAL PREREQUISITE: Supabase Project Setup
- [ ] Complete Manual Action #9 — Create Supabase project, obtain credentials
- [ ] Complete Manual Action #11 — Configure Supabase Auth settings
- [ ] Create `.env` file in `services/api/` with SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_JWT_SECRET

### Batch 19: Backend Auth Infrastructure
- [ ] Install backend deps: `@supabase/supabase-js`, `jsonwebtoken`, `@types/jsonwebtoken`, `dotenv`
- [ ] Add Supabase env vars to `services/api/src/config.ts`
- [ ] Create `services/api/src/db/supabase.ts` — Supabase client singleton (service role key)
- [ ] Create `services/api/src/auth/jwt.ts` — JWT verification utility (`verifySupabaseJwt(token) → { userId } | null`)
- [ ] Create `services/api/src/auth/fastify-auth-hook.ts` — Fastify `preHandler` hook for REST JWT auth
- [ ] Add `userId: string | null` to `ConnState` in `ws/handler.ts`
- [ ] Update `ws/handshake.ts` — dual-mode HELLO: JWT auth (resolve participant by userId) OR legacy token auth
- [ ] Add `AUTH_EXPIRED` error code to shared `ErrorCode` type
- [ ] Update `helloPayloadSchema` — make `participantId` optional
- [ ] Write tests: JWT verification, dual-mode handshake, AUTH_EXPIRED error
- [ ] Verify all 58 existing tests still pass (legacy path unchanged)

### Batch 20: Database Schema & Migration
- [ ] Create `services/api/src/db/migrations/001_initial_schema.sql` — full schema (profiles, friendships, sessions, session_participants, session_events, triggers, RLS policies, indexes)
- [ ] Complete Manual Action #10 — Run migration in Supabase SQL Editor
- [ ] Create `services/api/src/db/db-service.ts` — typed DB operations module:
  - `upsertProfile(userId, displayName)`
  - `getProfile(userId)`
  - `updateProfile(userId, updates)`
  - `createSessionRecord(sessionId, joinCode, hostUserId)`
  - `addSessionParticipant(sessionId, userId, participantId, displayName)`
  - `endSession(sessionId)`
  - `markParticipantLeft(sessionId, userId)`
  - `batchInsertEvents(sessionId, events[])`
  - `getUserSessions(userId)`
  - `getSessionEvents(sessionId)`
- [ ] Write tests: DB service operations (mocked Supabase client)

### Batch 21: Session Persistence Layer
- [ ] Create `services/api/src/db/event-flush.ts` — async batched event flush buffer:
  - Per-session in-memory buffer
  - Flush on: buffer ≥ 50 events, timer (5s interval), session end
  - Cap at 500 events per session (drop oldest on overflow)
  - Fire-and-forget with error logging
- [ ] Update `http/routes.ts` — add Fastify auth hook to `POST /sessions` and `POST /sessions/join`
  - Extract `userId` from verified JWT
  - Pass `userId` to session create/join
  - Async persist to Supabase after in-memory write
- [ ] Update `state/session-store.ts`:
  - Add `userId` field to `FullParticipantState`
  - `createSession(userId, displayName)` — accepts userId
  - `joinSession(joinCode, userId, displayName)` — accepts userId
  - Add `findParticipantByUserId(sessionId, userId)` method
- [ ] Wire event flush into event handlers (dispatcher or individual handlers):
  - On PARTICIPANT_JOINED, PARTICIPANT_LEFT, DESTINATION_SET, DESTINATION_CLEARED, CHAT_MESSAGE → push to flush buffer
  - On LOCATION_UPDATED → do NOT push (explicitly skip)
- [ ] Wire session end into cleanup sweep → call `endSession()` + flush remaining events
- [ ] Write tests: event flush buffer logic, session persistence integration

### Batch 22: User Profile & Friends API
- [ ] Create `services/api/src/http/profile-routes.ts`:
  - `GET /profile` — get own profile (authenticated)
  - `PUT /profile` — update display_name, avatar_url, settings (authenticated)
  - `GET /profile/:userId` — get another user's public profile
- [ ] Create `services/api/src/http/friends-routes.ts`:
  - `GET /friends` — list accepted friends + pending incoming requests (authenticated)
  - `POST /friends/request` — send friend request `{ userId }` (authenticated)
  - `POST /friends/:friendshipId/accept` — accept incoming request (authenticated)
  - `POST /friends/:friendshipId/reject` — reject incoming request (authenticated)
  - `DELETE /friends/:friendshipId` — remove friendship (authenticated)
  - `GET /friends/search?q=` — search users by display name (authenticated)
- [ ] Register profile + friends routes in `index.ts`
- [ ] Write tests: profile CRUD, friend request lifecycle, authorization checks

### Batch 23: Session History API
- [ ] Create `services/api/src/http/history-routes.ts`:
  - `GET /sessions/history` — list user's past sessions (authenticated, paginated)
  - `GET /sessions/:sessionId/events` — get event log for a past session (authenticated, must be participant)
  - `GET /sessions/:sessionId/summary` — get session summary (participants, duration, event counts)
- [ ] Register history routes in `index.ts`
- [ ] Write tests: history endpoints, authorization (only session participants can view)

### Batch 24: Mobile Auth Foundation
- [ ] Install mobile dep: `@supabase/supabase-js`
- [ ] Create `apps/mobile/src/services/supabase.ts` — Supabase client with AsyncStorage session persistence
- [ ] Create `apps/mobile/src/services/auth.ts` — auth service:
  - `register(email, password, displayName)`
  - `login(email, password)`
  - `logout()`
  - `getCurrentUser()`
  - `getAccessToken()` — returns current JWT (auto-refreshed)
  - `onAuthStateChange(callback)`
- [ ] Create `apps/mobile/src/state/auth-store.ts` — Zustand auth store:
  - `user: User | null`
  - `session: Session | null`
  - `isAuthenticated: boolean`
  - `isLoading: boolean`
- [ ] Create `apps/mobile/src/screens/LoginScreen.tsx` — email/password login
- [ ] Create `apps/mobile/src/screens/RegisterScreen.tsx` — email/password registration
- [ ] Update `App.tsx` — auth gate: show Login/Register if not authenticated, HomeScreen if authenticated
- [ ] Add logout button to HomeScreen or profile area

### Batch 25: Mobile API + WS Auth Integration
- [ ] Update `apps/mobile/src/services/api.ts`:
  - All HTTP calls include `Authorization: Bearer <jwt>` header
  - `createSession` and `joinSession` use JWT auth (no longer store random token)
  - Response no longer includes `token` field (or it's ignored)
- [ ] Update `apps/mobile/src/services/ws-client.ts`:
  - HELLO sends JWT as `token` (from Supabase session)
  - Remove `participantId` from HELLO payload (server resolves from JWT)
  - Handle `AUTH_EXPIRED` error → refresh token → reconnect
- [ ] Update `apps/mobile/src/state/session-store.ts`:
  - Remove `token` from stored session state (JWT is the token now)
  - `participantId` comes from WELCOME response
- [ ] Test full flow: register → login → create session → join session → WS handshake with JWT

### Batch 26: Mobile Friends & Profile UI
- [ ] Create `apps/mobile/src/screens/ProfileScreen.tsx` — view/edit own profile (display name, avatar)
- [ ] Create `apps/mobile/src/screens/FriendsScreen.tsx` — friends list, pending requests, search/add
- [ ] Create `apps/mobile/src/components/FriendRequestCard.tsx` — accept/reject UI
- [ ] Update navigation — add Profile and Friends tabs/screens
- [ ] Wire friend API calls to UI
- [ ] Wire profile API calls to UI

### Batch 27: Mobile Session History UI
- [ ] Create `apps/mobile/src/screens/SessionHistoryScreen.tsx` — list past sessions (from Supabase, not AsyncStorage)
- [ ] Create `apps/mobile/src/screens/SessionDetailScreen.tsx` — view event log of a past session
- [ ] Update HomeScreen — show session history from API instead of local AsyncStorage
- [ ] Wire history API calls to UI

### Batch 28: Migration Cleanup & Final Testing
- [ ] Remove legacy anonymous token support from backend:
  - `handshake.ts`: remove legacy token path
  - `session-store.ts`: remove `token` from `ParticipantState`
  - `routes.ts`: require auth on all mutating endpoints
  - Shared `HelloMessage`: remove optional `participantId`
- [ ] Update ALL existing tests to use JWT auth flow
- [ ] Run full test suite — ensure all pass
- [ ] Update `packages/shared/src/types.ts` — remove `token` from `ParticipantState`
- [ ] Update `packages/shared/src/validators.ts` — update `helloPayloadSchema`
- [ ] Final documentation review: ARCHITECTURE.md, WS-PROTOCOL.md, PRD.md, DECISIONS.md
- [ ] Complete Manual Action #12 — Update Fly.io env vars
- [ ] Git commit + push