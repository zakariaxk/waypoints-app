# Waypoints

Real-time social location sharing app for sessions where friends can see each other on a live map.

## Monorepo Structure

| Workspace | Path | Description |
|---|---|---|
| `@waypoints/shared` | `packages/shared` | Shared TypeScript types and validators |
| `@waypoints/api` | `services/api` | Fastify + ws backend |
| `@waypoints/mobile` | `apps/mobile` | React Native (Expo) client |

## Prerequisites

- Node.js >= 18
- npm >= 9 (ships with Node 18+)

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
```

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
