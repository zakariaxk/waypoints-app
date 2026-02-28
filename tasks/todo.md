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

## Remaining Manual Steps (see docs/MANUAL_ACTIONS.md)
- [ ] Apple Developer account enrollment ($99/yr)
- [ ] EAS project init (`eas login && eas init`)
- [ ] Deploy backend to Fly.io (`fly deploy`)
- [ ] Host privacy policy (GitHub Pages or similar)
- [ ] App Store Connect setup (create app, metadata, screenshots)
- [ ] EAS build: preview → TestFlight → production
- [ ] Submit for App Store review