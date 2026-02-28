# Waypoints

Real-time social location sharing app for sessions where friends can see each other on a live map.

## Features

- **Create & join sessions** via 6-character invite code
- **Live map** with real-time participant markers (react-native-maps)
- **Destination pin** — long-press the map to set a shared destination
- **Presence tracking** — online / stale / offline status per participant
- **Session chat** — in-app text messaging within your session
- **Reconnect-safe sync** — missed events replayed on reconnect via ring buffer
- **Share invite code** via system share sheet
- **Leave session** with confirmation and full state reset

## Monorepo Structure

| Workspace | Path | Description |
|---|---|---|
| `@waypoints/shared` | `packages/shared` | Shared TypeScript types, WS message types, Zod validators |
| `@waypoints/api` | `services/api` | Fastify HTTP + ws WebSocket backend |
| `@waypoints/mobile` | `apps/mobile` | React Native (Expo) client with live map |

## Prerequisites

- Node.js >= 18
- npm >= 9 (ships with Node 18+)
- Expo Go app (iOS/Android) for mobile development

## Getting Started

```bash
# Install all workspace dependencies
npm install

# Build shared types (required before backend/mobile)
npm run build:shared

# Start backend with hot reload (port 3000)
npm run dev:api

# Start mobile (separate terminal)
npm run dev:mobile

# Run backend tests (34 tests)
npm test
```

## API Endpoints

| Method | Path | Description |
|---|---|---|
| GET | `/health` | Health check |
| POST | `/sessions` | Create a new session |
| POST | `/sessions/join` | Join session by code |
| GET | `/sessions/:sessionId` | Get session info |

## WebSocket Protocol

See [docs/WS-PROTOCOL.md](docs/WS-PROTOCOL.md) for the full specification.

**Client messages:** `HELLO`, `LOC_UPDATE`, `SET_DESTINATION`, `CHAT_MESSAGE`, `LEAVE_SESSION`

**Server events:** `PARTICIPANT_JOINED`, `PARTICIPANT_LEFT`, `LOCATION_UPDATED`, `DESTINATION_SET`, `CHAT_MESSAGE`

## Scripts

| Command | Description |
|---|---|
| `npm install` | Install all workspace dependencies |
| `npm run build:shared` | Compile shared package |
| `npm run dev:api` | Start backend (tsx watch) |
| `npm run dev:mobile` | Start Expo dev server |
| `npm test` | Run backend tests (vitest) |
| `npm run lint` | Lint all workspaces |
| `npm run format` | Format all files (prettier) |

## Documentation

- [Product Requirements](docs/PRD.md)
- [Architecture](docs/ARCHITECTURE.md)
- [WebSocket Protocol](docs/WS-PROTOCOL.md)
- [Decisions](docs/DECISIONS.md)
- [Decisions](docs/DECISIONS.md)
