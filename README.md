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

## Local stack and harness

Requirements on top of the build: Docker running, and the Supabase CLI and `nats-server` (`make dev-install` runs `brew install supabase/tap/supabase nats-server`). `psql` is needed for `make check-db` (`brew install libpq`).

```sh
make dev        # supabase start, db reset (migrations + seed.sql), write server/.env and
                # ios/App/Config.xcconfig from `supabase status`, then run the gateway
make check-db   # supabase/checks.sql against the local database; non-zero if any rule prints FAIL
make check-rt   # server/cmd/rtdebug against a throwaway bench gateway; PASS or FAIL per scenario
make shot NAME=map ARGS="-wp-login marcus_s2k"                      # .build/shots/map.png
make shot NAME=g6 ARGS="-wp-preview -wp-open waypoints://debug/modsim"
make drive ROUTE=route-70                                           # moving location; ROUTE=stop clears
```

`make dev` options: `NO_RESET=1` keeps the database, `NO_GATEWAY=1` stops after writing the config files. Supabase keeps running after Ctrl-C; `supabase stop` stops it. Studio is at http://127.0.0.1:54323 and Inbucket (email codes) at http://127.0.0.1:54324.

**Seed users.** Every seed account (`supabase/seed.sql`) signs in with its email and the development password `waypoints-dev`. Handles: `marcus_s2k`, `dana_gti`, `priya_wrx`, `tkowalski`, `jaylen_e46`, `sofia_mk4`, `ray_foxbody`, `kenji_ae86`, `alexis_fl5`, `omar_350z`, `bree_a90`, `nick_evo` (emails are `first.last@waypoints.test`), and `deals4wheels`, a suspended account for moderation checks.

**check-rt scenarios** (plan W1-2): `friend-precise`, `approximate` (cell centre, no new position inside 15 s), `hidden`, `ghost` (gone within one tick), `nearby-anonymous` (no name, car, or heading), `viewport-swap` (gone for the old cells), `slow-consumer` (stalled reader closed with 4008 while a healthy viewer keeps up), `convoy` (precise while everything is hidden, stops after leave). `make check-rt ARGS="-only ghost,convoy -v"` runs a subset and logs frames. To point rtdebug at another gateway: `cd server && go run ./cmd/rtdebug -url http://127.0.0.1:8080 -secret <HS256 secret>`; the gateway must use the in-memory store with `WAYPOINTS_ENV=dev` or `bench`.

**shot** boots `SIMULATOR` (default iPhone 16), builds (skip with `BUILD=0`), installs, pins the location to Cherry Hill (`LOCATION=lat,lon`), launches with `ARGS`, waits `WAIT` seconds (default 6), and writes `.build/shots/<NAME>.png`. **drive** grants location to the app and runs `xcrun simctl location start` along `tools/dev/routes/<ROUTE>.txt` at `SPEED` m/s (default 15). Routes: `route-70`, `ben-franklin`, `pine-barrens`.

### Launch arguments

| Argument | Builds | Effect |
|---|---|---|
| `-wp-preview` | Debug | The environment is `PreviewEnvironment`: no backend, realistic seed data, signed in. |
| `-wp-login <handle>` | Debug, loopback Supabase URL only | Signs in as a seed user (or any email) with `waypoints-dev`. |
| `-wp-open <url>` | All | Opens a link once signed in. Debug builds add `waypoints://debug/<screen>`. |
| `-wp-smoke` | Debug | Calls every repository and service method once; prints `SMOKE PASS`, `FAIL`, or `SKIP` per method. Read it with `xcrun simctl launch --console booted app.waypoints.ios -wp-login marcus_s2k -wp-smoke`. |

Debug screens (`waypoints://debug/<name>`, `waypoints://debug/list` prints them): `map`, `search`, `route` (or `route-preview`), `nav`, `report`, `report-detail`, `convoy`, `help`, `spot`, `activity`, `meet`, `meet-start`, `feed`, `post`, `comments`, `showdown`, `rankings`, `market`, `listing`, `teams`, `team`, `channel` (or `team-channel`), `voice`, `thread`, `garage`, `profile`, `car` (or `garage-car`), `picker`, `modsim` (or `mod-simulator`), `strip`, `slip`, `settings`, `settings-privacy`, `settings-notifications`, `settings-blocked`, `settings-account`, `settings-about`, `report-sheet`, `terms`. Each opens the matching tab or route with the first fitting item from whichever backend is running. A feature exposes an internal screen or state (for example `feed/empty`) with `FeatureRegistry.registerDebugScreen`, which takes precedence.

Two simulators booted with different `-wp-login` handles cover every two-person flow.

## Layout

- `ios/App/`: app target. `CompositionRoot.swift` builds the `AppEnvironment` from each infrastructure module's `makeLive(config:)`.
- `ios/Packages/WaypointsKit/`: every Swift module from plan section 4.1. `Core` holds the domain models, repository protocols, plug-in contracts, and `PreviewEnvironment` (in-memory seed data for previews). `AppShell` holds the tabs, router, and deep links. Features plug in through `FeatureModule` and never import each other.
- `server/`: Go realtime gateway.
- `supabase/`: migrations, seed, and access-rule checks.
