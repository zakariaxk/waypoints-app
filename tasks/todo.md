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

## Remaining Manual Steps (see docs/MANUAL_ACTIONS.md)
- [ ] Apple Developer account enrollment ($99/yr)
- [ ] EAS project init (`eas login && eas init`)
- [ ] Deploy backend to Fly.io (`fly deploy`)
- [ ] Host privacy policy (GitHub Pages or similar)
- [ ] App Store Connect setup (create app, metadata, screenshots)
- [ ] EAS build: preview → TestFlight → production
- [ ] Submit for App Store review