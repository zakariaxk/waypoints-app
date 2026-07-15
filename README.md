# Waypoints

[![CI](https://github.com/zakariaxk/waypoints-app/actions/workflows/ci.yml/badge.svg)](https://github.com/zakariaxk/waypoints-app/actions/workflows/ci.yml)

Real-time location sharing app — create a session, share the code, see everyone on a live map. 

## Features

### Core
- **Instant sessions** — create and join via 6-character invite code or deep link
- **Live map** — real-time participant markers with per-user colors
- **Host controls** — set/clear shared destination, accept destination proposals
- **Distance & ETA** — OSRM-powered driving distance and live ETA for each participant
- **Presence tracking** — online / stale / offline status with faded offline markers
- **Session chat** — in-app messaging within your group
- **Reconnect-safe** — exponential backoff with event replay (no missed updates)

### Enhanced
- **Per-user route colors** — 8-color neon palette, unique per participant
- **Arrival detection** — ✓ Arrived badge when within 50m of destination
- **Movement status** — 🚗 Driving / 🚶 Walking / 📍 Stationary from speed data
- **Follow mode** — lock camera to a friend's position, auto-disable on manual pan
- **Group ETA summary** — fastest / average / longest ETA at a glance
- **Session summary** — post-session stats with arrival order, duration, distances
- **Destination voting** — non-hosts propose via long-press, host accepts
- **Map modes** — standard / satellite / hybrid toggle
- **Session history** — rejoin recent sessions from home screen
- **Dark/light mode** — persisted toggle with AsyncStorage

### UI
- **Neon-tech design system** — deep-space blacks, cyan/magenta/violet/lime/amber accents
- **Custom typography** — Orbitron (headings) + Rajdhani (body) Google Fonts
- **Glow effects** — colored shadows on iOS, elevation on Android
- **Translucent panels** — frosted glass HUD aesthetic
- **Haptic feedback** — tactile response on all interactive elements
- **6 reusable components** — NeonText, NeonButton, HudCard, Chip, NeonDivider, BottomSheetPanel

## Architecture

| Workspace | Path | Description |
|---|---|---|
| `@waypoints/shared` | `packages/shared` | TypeScript types, WS messages, Zod validators |
| `@waypoints/api` | `services/api` | Fastify HTTP + ws WebSocket backend (44 tests) |
| `@waypoints/mobile` | `apps/mobile` | React Native (Expo SDK 54) client |

## Tech Stack

**Backend:** Node.js, Fastify, ws, Zod, Vitest  
**Mobile:** React Native, Expo SDK 54, React 19, TypeScript  
**UI:** expo-linear-gradient, expo-blur, expo-font, expo-haptics  
**Maps:** react-native-maps, OSRM routing API  
**State:** Zustand, AsyncStorage  
**Fonts:** Orbitron, Rajdhani (Google Fonts via @expo-google-fonts)

## Getting Started

```bash
# Install all workspace dependencies
npm install

# Build shared types (required first)
npm run build:shared

# Start backend (port 3000)
npm run dev:api

# Start mobile (separate terminal)
npm run dev:mobile

# Run tests (44 passing)
npm test
```

## Production Deployment

### Backend (Render)
```bash


# Render (currently deployed)
# Auto-deploys from main branch
# Live at https://waypoints-api.onrender.com
```

### Mobile (EAS Build)
```bash
cd apps/mobile

# Install EAS CLI and login
npm install -g eas-cli
eas login
eas init

# Development build (simulator)
eas build --platform ios --profile development

# Preview build (TestFlight)
eas build --platform ios --profile preview

# Production build + submit
eas build --platform ios --profile production
eas submit --platform ios --profile production
```

### Docker
```bash
docker build -t waypoints-api .
docker run -p 8080:8080 waypoints-api
```

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check (uptime, session count) |
| POST | `/sessions` | Create a new session |
| POST | `/sessions/join` | Join session by code |
| GET | `/sessions/:sessionId` | Get session info |

## WebSocket Protocol

See [docs/WS-PROTOCOL.md](docs/WS-PROTOCOL.md) for the full specification.

**Client →** `HELLO`, `LOC_UPDATE`, `SET_DESTINATION`, `CLEAR_DESTINATION`, `CHAT_MESSAGE`, `LEAVE_SESSION`

**Server →** `WELCOME`, `SNAPSHOT`, `EVENTS`, `ERROR`, `EVENT` (with kinds: `PARTICIPANT_JOINED`, `PARTICIPANT_LEFT`, `LOCATION_UPDATED`, `DESTINATION_SET`, `DESTINATION_CLEARED`, `CHAT_MESSAGE`)

## Scripts

| Command | Description |
|---|---|
| `npm install` | Install all workspace dependencies |
| `npm run build:shared` | Compile shared package |
| `npm run dev:api` | Start backend (tsx watch) |
| `npm run dev:mobile` | Start Expo dev server |
| `npm test` | Run backend tests (vitest, 44 tests) |
| `npm run lint` | Lint all workspaces |
| `npm run format` | Format all files (prettier) |
| `node scripts/generate-assets.js` | Regenerate app icons/splash |

## Documentation

- [Product Requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [WebSocket Protocol](docs/WS-PROTOCOL.md)
- [UI Style Guide](docs/UI_STYLEGUIDE.md)
- [Privacy Policy](docs/PRIVACY_POLICY.md)
- [App Store Metadata](docs/APP_STORE_METADATA.md)
- [Manual Actions](docs/MANUAL_ACTIONS.md)
- [Decisions](docs/DECISIONS.md)

## App Store Checklist

See [docs/MANUAL_ACTIONS.md](docs/MANUAL_ACTIONS.md) for the step-by-step submission guide.

1. ✅ App icon, splash screen, adaptive icon generated
2. ✅ `eas.json` with dev/preview/production profiles
3. ✅ `app.config.ts` with bundle IDs and versioning
4. ✅ Privacy policy written
5. ✅ App Store metadata (description, keywords, screenshots guide)
6. ✅ Dockerfile + fly.toml for backend deployment
7. ✅ Backend deployed to Render
8. ⬜ Apple Developer account + EAS project init (manual)
9. ⬜ Privacy policy hosted (manual)
10. ⬜ EAS build + TestFlight test (manual)
11. ⬜ App Store submission (manual)
