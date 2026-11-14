# Waypoints

A native iOS social map for the car community: live friends on the map, meets, teams, builds, a mod simulator, and a virtual drag strip. Swift 6 client, Go realtime gateway, Supabase.

The project is being rewritten from scratch. [docs/PRD.md](docs/PRD.md) is the source of truth for what is built: every requirement, its priority and status, and the remaining work packages. [docs/PLAN.md](docs/PLAN.md) is the source of truth for how: architecture, wire protocol, design system, and every screen. The previous Expo app and TypeScript WebSocket service are in git history before the cleanup commit.

## Build

Requirements: Xcode 16.3 (Swift 6.1), Go, and XcodeGen (`brew install xcodegen`).

```sh
make build      # the gate: go build and vet, xcodegen, xcodebuild for the simulator
make run        # build and launch in the iPhone 16 simulator (SIMULATOR="iPhone 16 Pro" to change)
make generate   # regenerate ios/Waypoints.xcodeproj only
```

The Xcode project is generated from `ios/project.yml` and not committed. Open `ios/Waypoints.xcodeproj` after `make generate`.

Configuration lives in `ios/App/Config.xcconfig` (gitignored): Supabase URL and anon key, and the gateway URL. `make` copies `ios/App/Config.example.xcconfig` there if it is missing, which points at a local `supabase start` and a local gateway.

## Layout

- `ios/App/`: app target. `CompositionRoot.swift` builds the `AppEnvironment` from each infrastructure module's `makeLive(config:)`.
- `ios/Packages/WaypointsKit/`: every Swift module from plan section 4.1. `Core` holds the domain models, repository protocols, plug-in contracts, and `PreviewEnvironment` (in-memory seed data for previews). `AppShell` holds the tabs, router, and deep links. Features plug in through `FeatureModule` and never import each other.
- `server/`: Go realtime gateway.
- `supabase/`: migrations, seed, and access-rule checks.
