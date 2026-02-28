# Waypoints

Real-time location sharing app — create a session, share the code, see everyone on a live map.

## Features

- **Instant sessions** — create and join via 6-character invite code
- **Live map** — real-time participant markers with status colors
- **Host controls** — only the host can set/clear the shared destination
- **Distance & ETA** — see how far you are from the destination
- **Presence tracking** — online / stale / offline status per participant
- **Session chat** — in-app messaging within your group
- **Reconnect-safe** — exponential backoff reconnect with event replay
- **Session history** — rejoin recent sessions from the home screen
- **Persistent identity** — display name saved across sessions
- **Error boundary** — graceful crash recovery
- **Host badge** — 👑 shown next to the session creator

## Architecture

| Workspace | Path | Description |
|---|---|---|
| `@waypoints/shared` | `packages/shared` | TypeScript types, WS messages, Zod validators |
| `@waypoints/api` | `services/api` | Fastify HTTP + ws WebSocket backend (44 tests) |
| `@waypoints/mobile` | `apps/mobile` | React Native (Expo SDK 52) client |

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

### Backend (Fly.io)
```bash
# Install Fly CLI
brew install flyctl

# Login and deploy
fly auth login
fly launch    # uses existing fly.toml
fly deploy

# Verify
curl https://waypoints-api.fly.dev/health
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

# Production build
eas build --platform ios --profile production

# Submit to App Store
eas submit --platform ios --profile production
```

### Docker
```bash
# Build and run locally
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
7. ⬜ Apple Developer account + EAS project init (manual)
8. ⬜ Backend deployed to Fly.io (manual)
9. ⬜ Privacy policy hosted (manual)
10. ⬜ EAS build + TestFlight test (manual)
11. ⬜ App Store submission (manual)
