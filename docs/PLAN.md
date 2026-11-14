# Waypoints: rewrite plan

Native iOS social map for the car community. Swift 6 client, Go realtime gateway, Supabase for everything durable.

This document is the source of truth for how Waypoints is built. `docs/PRD.md` sits above it: it decides scope, priority, the status of every requirement, and all work from wave 6 on, and it wins where the two disagree. The work packages in section 12 (waves 0 to 5) have been coded and are kept as a record. If a package and a shared section disagree, the shared section wins; fix the package.

Written 2026-11-09. Facts marked *(verify)* came from research that could not be confirmed against a primary source; the package that depends on one must check it first.

## Contents

1. Decisions already made
2. Product
3. Architecture
4. Repository layout and module boundaries
5. Data model
6. Wire protocol
7. Realtime gateway design
8. Performance targets and benchmark
9. Design system
10. Screens
11. Feature engineering notes (catalog, performance model, audio, race, navigation)
12. Work packages
13. Waves
14. Manual actions for the owner
15. What was left out, and why
16. Carried over from the old codebase

---

## 1. Decisions already made

| Decision | Choice | Reason |
|---|---|---|
| Minimum iOS | iOS 18.0, built with the installed Xcode 16.3 and Swift 6.1 | Owner's choice. Builds today with no OS upgrade. Consequence: no Liquid Glass; the look is fully custom (section 9). |
| Swift language mode | Swift 6, complete strict concurrency in every target | The client's concurrency story is part of the resume headline. |
| Map | Apple MapKit | Owner's choice. Free, no keys. Consequence: turn-by-turn is built in-app from `MKRoute` steps, and low-car routing can only choose among Apple's alternates (section 11.5). |
| Budget | Free tiers only | Owner's choice. The single unavoidable cost is the Apple Developer Program ($99/year), and only from wave 3 (section 14). |
| Backend | Rewrite the realtime service in Go. Delete the TypeScript service. | Section 7.1. |
| Durable data, auth, storage, chat delivery | Supabase (Postgres + PostGIS, Auth, Storage, Realtime) | Already in use, free tier, removes four services we would otherwise write. |
| Wire format | Protocol Buffers over WebSocket (binary frames, TLS) | Section 6. |
| Inter-node bus | NATS core (no JetStream) | Section 7.6. |
| Voice | LiveKit Cloud free plan | An SFU is required for Discord-style channels; a mesh tops out near 5 peers. |
| Theme | Dark only | Section 9.1. |
| Monetization | None | Out of scope, and "no pay-to-win" is a stated advantage over the reference competitor. |
| Workflow | Everything commits to `main`. No branches, PRs, or test targets. Gate: `make build` exits 0. | Owner's rule. |

---

## 2. Product

### 2.1 What it is

One app where a car person can see who is out driving, find or start a meet, talk to their team, show their build, and play with it (simulate mods, hear it, race it virtually).

### 2.2 Reference competitor and how to beat it

Reference: LiveMap (livemap.co, "LiveMap: Drive & Connect"). Findings from its site, FAQ, and App Store listing on 2026-11-09: Mapbox map; convoys with push-to-talk; route generator with a twistiness control; meets with RSVP; communities with channels; feed and short videos; weekly car-vs-car voting; garage with rarity tiers; two subscriptions ($12.99 and $24.99 per month) plus a purchasable currency that buys boosts, prize-wheel spins, and leaderboard advantages; free convoys capped at 10; 306 MB download; 41 ratings. Do not copy its name, wording, or assets.

| Axis | LiveMap | Waypoints |
|---|---|---|
| Privacy | One sharing switch, mutual follows only. Convoy members see your speed. | Per-audience precision (precise, approximate, hidden), timed ghost mode, home zones, server-side fuzzing so imprecise viewers never receive real coordinates. Nobody ever sees another person's speed. |
| Fairness | Paid leaderboard boosts, prize wheel, capped convoys. | Nothing is for sale. Rankings are votes only. Convoys are unlimited. |
| Safety | Shows live speeds, gives points for driving. | No speed display for others, no points for distance or speed, racing exists only as a clearly virtual game. |
| Weight | 306 MB. | Target under 60 MB installed. Few dependencies (section 4.4). |
| Empty map | Depends on friends being online. | Useful alone: hazard reports, rated roads, recurring meets, and car spots are durable map content. |
| Latency | Not published. | Measured and published: section 8. |
| Depth for builders | Garage is a collection. | Full catalog picker, build timeline, mod simulator with honest ranges, synthesized exhaust, virtual drag strip driven by the same model. |
| Moderation | None documented. | Report, block, filter, and a published contact from the first wave that ships user content. |

### 2.3 Pillars

Each borrows one proven pattern.

| Pillar | Pattern | Scope in this plan |
|---|---|---|
| Map | DrivnBye, Waze | Live friends, approximate nearby drivers, navigation, community reports, user-chosen vehicle markers. |
| Meets | Facebook Events | Anyone drops a meet on the map in three fields; nearby users are notified. |
| Teams | Discord | Servers with text channels, voice channels, roles. |
| Showdown | Tinder | Two builds, pick one. Elo rankings. |
| Profiles | Instagram | Person plus garage; each car has photos and a build timeline. |
| Feed | TikTok | Full-screen vertical video. |
| Garage | (own design) | Year, make, model, trim, color from a full catalog (section 11.1). |
| Mod simulator | (own design) | Section 11.2 and 11.3. |
| Marketplace | Craigslist-simple | Parts and cars, listings, messaging. No payments. |
| Race | Arcade drag strip | Virtual only (section 11.4). |

### 2.4 Proposals: features nobody in this space ships

These are proposals, not commitments. Each is scheduled in a wave so it can be cut without affecting others.

| Proposal | What it is | Novelty | Wave |
|---|---|---|---|
| **Low-car routing** | Each car has a clearance profile (stock, lowered, slammed). Route preview scores Apple's alternate routes against community reports of speed bumps, steep driveways, potholes, and rough surface, and warns per hazard: "2 speed bumps on this route." | Not on iOS. One Android beta claims it *(verify)*. | 2 |
| **Venue notes for meets** | A meet location carries community notes: entrance steepness, lot size, lighting. Confirmed and decayed like reports. | Not found anywhere. | 2 |
| **Convoy with regroup** | Shared route and live positions are table stakes (several apps have them). The addition: the app notices when the convoy has split by more than a set time gap and offers the lead a "Regroup" prompt that drops a pull-off pin for everyone. | Regroup detection not found. | 2 |
| **Car spotting collection** | Photograph a car, tag it from the catalog, and it joins your collection grouped by make and model. Plates are blurred on-device before upload. Location is stored at city level only. | Exists as standalone apps; not fused with a social map. | 5 |
| **Road ratings** | Save a stretch from a drive you recorded, rate it on surface, scenery, and traffic. Rated roads draw on the map. | Algorithmic twistiness exists; community ratings for cars do not. | 5 |
| **Driven map** (backlog) | Percentage of your region's road cells you have driven. Rewards exploring, not speed. | Zenly did this for places, nobody for roads. | not scheduled |
| **Passed-you digest** (backlog) | Opt-in, delayed, blurred note that you and another member crossed paths today. | Not found. | not scheduled |

### 2.5 Privacy model

Privacy is enforced on the server. A viewer who is not entitled to precise location never receives it.

- **Audiences**: Friends, Team members, Convoy (always precise while the convoy is active, and the join screen says so), Nearby (strangers).
- **Levels per audience**: Precise, Approximate, Hidden.
  - *Precise*: real position at up to 1 Hz, with heading.
  - *Approximate*: position snapped to the centre of an H3 resolution 8 cell (about 0.5 km across), no heading, at most one update every 15 s.
  - *Hidden*: nothing is sent; the viewer cannot tell hidden from offline.
- **Defaults**: Friends Precise, Team Approximate, Nearby Hidden. Onboarding asks about Nearby once, with Hidden preselected.
- **Nearby is never Precise.** The setting offers only Approximate or Hidden.
- **Ghost mode**: overrides everything to Hidden. Durations: 1 hour, until tomorrow 6:00, until turned off. An active convoy pauses ghost mode only after an explicit confirmation.
- **Home zones**: up to three circles (radius 300 m, centre chosen by the user). Inside one, every audience is capped at Approximate and Nearby is Hidden. The zone centre is stored only on the device and sent to the gateway over TLS at connect; the gateway keeps it in memory, never in Postgres.
- **Speed**: your own speed appears only on your navigation screen. It is never transmitted to other clients. The gateway strips it during fan-out.
- **Stored location**: Postgres stores only an H3 resolution 7 cell (about 5 km²) per user, for "notify me about meets nearby". No track history on the server. Drive traces for road ratings stay on the device until the user saves a stretch.
- **Minimum age**: 17. Asked at sign-up.

---

## 3. Architecture

```
 iPhone (Swift 6)                         Server side
 ┌──────────────────────────┐
 │ SwiftUI features         │   HTTPS (PostgREST, Auth, Storage)   ┌───────────────────┐
 │  └ repositories ─────────┼──────────────────────────────────────▶│ Supabase          │
 │                          │   WSS (Supabase Realtime: chat rows)  │  Postgres+PostGIS │
 │  └ chat streams ◀────────┼───────────────────────────────────────│  Auth, Storage    │
 │                          │                                       └─────────▲─────────┘
 │ RealtimeClient (actor) ◀─┼── WSS, protobuf binary frames ──┐               │ pgx
 │ LocationKit   (actor) ───┼──▶                              ▼               │
 │ GatewayAPI ──────────────┼── HTTPS (JSON) ────────▶ ┌──────────────────────┴──┐
 │ VoiceFeature (LiveKit) ──┼── WebRTC ──▶ LiveKit     │ Go gateway (N nodes)    │──▶ APNs
 └──────────────────────────┘             Cloud        │  hub shards by H3 cell  │
                                                       └───────────▲─────────────┘
                                                                   │ NATS core
                                                            (only when N > 1)
```

### 3.1 Who owns what

| Concern | Owner | Why there |
|---|---|---|
| Live location, presence, convoy positions | Go gateway, in memory | Ephemeral, high rate, latency-critical. Never touches the database on the hot path. |
| Privacy enforcement for location | Go gateway | Fuzzing must happen before data leaves the server. |
| Writes that need instant geographic fan-out or a push (create report, create meet, convoy lifecycle, privacy settings) | Go gateway HTTP API, which writes Postgres then publishes | One place does write + fan-out + push. |
| Voice tokens | Go gateway HTTP API | LiveKit secret must stay server-side. |
| Push | Go gateway, direct APNs HTTP/2 | No third-party push service. |
| Everything else durable (profiles, cars, posts, teams, messages, listings, votes) | Client talks to Supabase directly, guarded by row-level security | No server code to write. |
| Live chat delivery | Supabase Realtime (Postgres Changes on `messages`) | Durable, ordered, zero server code. Small user counts make its limits irrelevant. |
| Media | Supabase Storage | Free tier 1 GB *(verify)*; limits in section 15. |

### 3.2 Client concurrency model

- Every piece of shared mutable state lives in an `actor` or on `@MainActor`. No locks, no `@unchecked Sendable` outside `EngineAudio`'s render kernel (section 11.3), no `nonisolated(unsafe)`.
- View models are `@MainActor @Observable` classes. They hold `Task`s tied to view lifetime with `.task {}`.
- Realtime data flows as `AsyncSequence`:
  - `RealtimeClient` (actor) owns the socket. It exposes `AsyncStream<ServerEvent>` with `.bufferingNewest(256)`.
  - `LocationKit.LocationService` (actor) wraps `CLLocationUpdate.liveUpdates(.automotiveNavigation)` and exposes `AsyncStream<LocationSample>`.
  - `MapFeature.LiveEntityStore` (actor) consumes server events, keeps the latest state per entity, and publishes diff batches to the main actor at most 10 times per second.
- Structured concurrency: connection lifecycle is one `withThrowingTaskGroup` with three children (receive loop, send loop, heartbeat). Cancelling the group tears all three down. Reconnect is a loop around the group with exponential backoff and full jitter (0.5 s doubling to 30 s, reset after 30 s of stable connection). `NWPathMonitor` path changes trigger an immediate attempt.
- All domain models are `Sendable` value types.

### 3.3 Client-side location policy

| State | Send rate | How detected |
|---|---|---|
| Driving (speed ≥ 5 m/s) | 1 Hz | `CLLocation.speed` |
| Slow (1 to 5 m/s) | every 3 s | speed |
| Stationary | nothing; a heartbeat ping every 25 s | `CLLocationUpdate.stationary` |
| Backgrounded, no convoy or navigation | stop sharing after 5 minutes stationary; resume on movement | `CLBackgroundActivitySession` held only while sharing is on |

Authorization: request When In Use during onboarding; request Always only when the user turns on "Keep sharing when the app is closed", with a screen that explains it first.

---

## 4. Repository layout and module boundaries

```
/
├─ Makefile                  build gate and codegen entry points
├─ README.md
├─ docs/PLAN.md              this file
├─ docs/BENCHMARKS.md        produced by benchmark packages
├─ proto/waypoints/v1/       .proto sources (the wire contract)
├─ supabase/migrations/      SQL, timestamp-prefixed
├─ server/                   Go module `waypoints/server`
│  ├─ cmd/gateway/           main
│  ├─ cmd/loadgen/           load generator
│  └─ internal/
│     ├─ app/                config, lifecycle, package registry
│     ├─ wire/               generated Go protobuf
│     ├─ auth/               Supabase JWT verification (JWKS)
│     ├─ ws/                 connection, read and write pumps, outbox
│     ├─ hub/                cell shards, subscriptions, fan-out
│     ├─ geo/                H3 helpers, viewport cover, fuzzing
│     ├─ privacy/            entitlements, home zones, ghost
│     ├─ bus/                Bus interface, in-process impl
│     ├─ bus/natsbus/        NATS impl
│     ├─ store/              pgx queries
│     ├─ api/                HTTP handlers: settings, reports, meets
│     ├─ convoy/             convoy state and HTTP handlers
│     ├─ voice/              LiveKit token minting
│     ├─ push/               APNs client, notification rules
│     └─ metrics/            Prometheus-format counters and histograms
├─ tools/
│  ├─ catalog/               Go: builds the vehicle catalog SQLite
│  └─ mods/                  mod catalog source data (JSON)
├─ bench/                    scenarios, run scripts, raw results
├─ deploy/                   Dockerfile, compose file, Caddyfile
└─ ios/
   ├─ project.yml            XcodeGen spec (the .xcodeproj is generated, not committed)
   ├─ App/                   app target: entry point, composition root, Info.plist, assets, entitlements
   └─ Packages/WaypointsKit/
      ├─ Package.swift       declares every module below from wave 0
      └─ Sources/<Module>/
```

### 4.1 Swift modules

Layer rule: a module may import only modules in rows above it. Feature modules never import each other.

| Layer | Module | Contents |
|---|---|---|
| 0 | `Core` | Domain models, IDs, errors, repository protocols, `MapLayerProvider` and other plug-in protocols, `AppEnvironment`, `Route`. No UI, no dependencies. |
| 0 | `WireProtocol` | Generated swift-protobuf types. |
| 1 | `DesignSystem` | Tokens, components, map icon set, haptics, motion. Imports nothing but SwiftUI. |
| 1 | `Backend` | Supabase-backed implementations of `Core` repository protocols; auth session. |
| 1 | `GatewayAPI` | HTTPS client for the Go gateway's JSON API. |
| 1 | `RealtimeClient` | WebSocket actor, reconnect, `AsyncStream<ServerEvent>`. |
| 1 | `LocationKit` | Location actor, adaptive sampler, home zones. |
| 1 | `VehicleCatalog` | SQLite catalog reader, search, update check. |
| 1 | `PerformanceModel` | Pure functions: specs + mods → estimates. |
| 1 | `EngineAudio` | Synthesizer. |
| 1 | `SafetyKit` | Report and block flows, text filter, EULA gate. |
| 2 | `MapFeature`, `NavigationFeature`, `ReportsFeature`, `MeetsFeature`, `ConvoyFeature`, `MessagingFeature`, `TeamsFeature`, `VoiceFeature`, `FeedFeature`, `ShowdownFeature`, `GarageFeature`, `ModSimFeature`, `RaceFeature`, `MarketFeature`, `SpotsFeature`, `RoadsFeature`, `ProgressFeature`, `OnboardingFeature`, `SettingsFeature`, `PushKitBridge` | One feature each. |
| 3 | `AppShell` | Tab container, router, deep links, plug-in registry. Imports every feature. |

### 4.2 How parallel agents avoid colliding

1. **Every module exists from wave 0.** Package W0-A creates each target with one file, `Sources/<Module>/<Module>.swift`, containing the module's public entry point with a stub body. The owning package later replaces that file and adds others. Nobody but W0-A and integration packages edits `Package.swift`.
2. **Features plug in, they do not reach in.** `Core` defines the plug-in protocols (section 4.3). `AppShell` (written in wave 0) already calls every feature's entry point. A feature that is not built yet returns `isAvailable == false` and the shell hides it. So no later package edits `AppShell` or `MapFeature` to add itself.
3. **Schema is laid down once.** W0-C writes every table in section 5. A later package that needs a change adds a new file `supabase/migrations/<UTC timestamp>_<package id>_<name>.sql`; it never edits an existing migration.
4. **The Go gateway uses the same trick.** W0-B writes `cmd/gateway/main.go` so that it calls `Register(*app.App)` on every `internal/` package listed above; unbuilt packages have an empty `Register`.
5. **Each wave ends with one integration package that runs alone** and may touch any file.
6. Agents commit only files inside their package's "Owns" list. Before committing: `git pull --rebase`, then `make build`.

### 4.3 Shared contracts (defined in `Core` by W0-A)

Signatures are normative. Bodies and extra helpers are the implementer's choice.

```swift
// Identity
public struct UserID: Hashable, Sendable, Codable { public let raw: UUID }
public typealias RealtimeUID = UInt64          // compact numeric id used on the wire (profiles.uid)
public struct Coordinate: Hashable, Sendable, Codable { public var latitude, longitude: Double }

// Environment handed to every feature
public struct AppEnvironment: Sendable {
    public let auth: any AuthService
    public let profiles: any ProfileRepository
    public let garage: any GarageRepository
    public let friends: any FriendRepository
    public let meets: any MeetRepository
    public let reports: any ReportRepository
    public let teams: any TeamRepository
    public let messages: any MessageRepository
    public let posts: any PostRepository
    public let showdown: any ShowdownRepository
    public let market: any MarketRepository
    public let spots: any SpotRepository
    public let roads: any RoadRepository
    public let progress: any ProgressRepository
    public let media: any MediaStore
    public let realtime: any RealtimeService
    public let location: any LocationService
    public let gateway: any GatewayService
    public let catalog: any VehicleCatalogService
    public let safety: any SafetyService
    public let router: any Router
    public let activity: any ActivityRepository   // NTF-6, W7-2
}

// Realtime (implemented by RealtimeClient)
public protocol RealtimeService: Sendable {
    func events() async -> AsyncStream<ServerEvent>          // multi-consumer: each call gets its own stream
    func connectionState() async -> AsyncStream<ConnectionState>
    func setViewport(_ region: MapRegion) async
    func send(_ sample: LocationSample) async
    func joinConvoy(_ id: ConvoyID) async
    func leaveConvoy() async
}
public enum ServerEvent: Sendable {
    case entities([EntityUpdate])          // conflated positions
    case gone([RealtimeUID])
    case aggregates([CellAggregate])       // low-zoom counts
    case mapEvent(MapEvent)                // report or meet created, changed, removed
    case convoy(ConvoyState)
}
public enum ConnectionState: Sendable { case connecting, live, reconnecting(attempt: Int), offline }

// Location (implemented by LocationKit)
public protocol LocationService: Sendable {
    func samples() async -> AsyncStream<LocationSample>
    func authorization() async -> AsyncStream<LocationAuthorization>
    func requestWhenInUse() async
    func requestAlways() async
    func setSharing(_ on: Bool) async
    func homeZones() async -> AsyncStream<[HomeZone]>          // device-only storage (2.5): current list, then changes
    func setHomeZones(_ zones: [HomeZone]) async throws        // at most HomeZone.maximumCount
}

// Map plug-ins (consumed by MapFeature, supplied by other features through AppShell)
public protocol MapLayerProvider: Sendable {
    var id: String { get }
    func items(in region: MapRegion) -> AsyncStream<[MapItem]>      // re-called when the camera settles
    @MainActor func detail(for item: MapItem) -> AnyView?           // shown in the map sheet on selection
}
public struct MapItem: Identifiable, Sendable {
    public let id: String
    public var coordinate: Coordinate
    public var glyph: MapGlyph            // DesignSystem-rendered by name
    public var tint: MapTint
    public var title: String?
    public var priority: Int              // higher wins when crowded
}
public protocol MapSheetSection: Sendable {                         // rows in the map's bottom sheet
    var id: String { get }; var order: Int { get }
    @MainActor func view(region: MapRegion) -> AnyView
}
public protocol MapAction: Sendable {                                // entries in the map's add menu
    var id: String { get }; var title: String { get }; var symbol: String { get }; var order: Int { get }
    @MainActor func perform(at coordinate: Coordinate, router: any Router)
}

public protocol FeedMode: Sendable {                                 // extra modes in the Feed tab's top switch (Showdown)
    var id: String { get }; var title: String { get }; var order: Int { get }
    @MainActor func view() -> AnyView
}

// Feature entry point: every feature module exposes one value conforming to this
public protocol FeatureModule: Sendable {
    static var isAvailable: Bool { get }
    @MainActor static func register(in registry: FeatureRegistry, env: AppEnvironment)
}

// Navigation between features without importing each other
public enum Route: Hashable, Sendable {
    case profile(UserID), car(CarID), meet(MeetID), team(TeamID), channel(ChannelID), voice(ChannelID), thread(ThreadID)
    case listing(ListingID), post(PostID), report(ReportID), vehiclePicker(forCar: CarID?)
    case modSim(CarID), race(CarID), reportContent(ContentRef), settings, settingsPrivacy, createMeet(Coordinate?)
    case createReport(Coordinate), spotCar
    case navigate(to: Coordinate, name: String?)
    case joinTeam(code: String), joinConvoy(code: String)     // invite deep links (X3)
    case activity                                             // NTF-6 Activity list (W7-2)
}
public protocol Router: Sendable { @MainActor func open(_ route: Route) }
```

`settings` opens S1 (Garage's gear button), `createReport` opens M5 at a point (the Reports add-menu action), `spotCar` opens M12, and `voice` opens T3 for a voice channel (Teams shows voice rows only when a handler exists). `joinConvoy(code: "")` opens the convoy start-or-join sheet. `ProfileRepository` also carries `notificationPrefs()` and `setNotificationPrefs(_:)` over the `notification_prefs` table (S3, migration W3-4). `SafetyKit.makeLive(config:auth:profiles:)` talks to PostgREST directly. `ProgressRepository.raceResults(by:limit:)` returns another user's fastest runs for the Strip's friend opponent.

Contract change (W7-2, NTF-6): `ActivityRepository` (`Core/Repositories/ActivityRepository.swift`) reads the `notifications` table: `recent(limit:)` newest first, `markAllRead()`, and `unreadCount()` (current value, then changes). Models `ActivityItem` and `ActivityKind`. `AppEnvironment.activity` is the last init parameter and defaults to `PreviewActivity.shared`; `Backend.Services.activity` is `LiveActivity`. `Route.activity` opens the Activity list, registered by `PushKitBridge` (pushed on the Garage tab); Garage's bar shows the bell only when that route has a handler.

Home zones reach the gateway without a feature in the loop: `RealtimeClient.makeLive(config:auth:location:)` takes the `LocationService`, subscribes to `homeZones()`, and sends `SetHomeZones` at every connect and on every change.

`FeatureRegistry` lets a feature register: a tab (title, SF Symbol, root view, optional reselect hook and badge count), route handlers (`Route` case → view, with push, sheet, or full-screen presentation), map layer providers, map sheet sections, map actions, feed modes, and the onboarding flow (the signed-out root, registered by `OnboardingFeature`).

Repository protocols follow one shape: `async throws` functions returning `Sendable` models, plus `AsyncStream` where live updates exist. W0-A writes them all, one file per repository in `Core/Repositories/`, derived from section 5. `Core` also ships `PreviewEnvironment`, an in-memory implementation of every protocol with realistic seed data (real car names, plausible meets), so every feature can be built and previewed before `Backend` exists.

### 4.4 Dependencies

Each must earn its place.

| Dependency | Used by | Why it earns it |
|---|---|---|
| `supabase-swift` | `Backend` | Auth, PostgREST, Storage, Realtime in one maintained client. |
| `swift-protobuf` | `WireProtocol` | Wire contract. |
| `GRDB.swift` | `VehicleCatalog` | SQLite with FTS5 and Swift 6 support; avoids hand-rolled C bindings. |
| `client-sdk-swift` (LiveKit) | `VoiceFeature` | Voice. Imported only by that module. |
| Go: `coder/websocket`, `uber/h3-go/v4`, `jackc/pgx/v5`, `nats.go`, `golang-jwt/jwt/v5`, `HdrHistogram/hdrhistogram-go`, `google.golang.org/protobuf` | server | One job each. |

Nothing else without a line added to this table by the package that needs it. No analytics SDK, no crash SDK (MetricKit is enough), no image-loading library (`AsyncImage` plus a 40-line cache in `DesignSystem`), no Lottie, no architecture framework.

---

## 5. Data model

Postgres on Supabase with PostGIS. All tables have row-level security on. `uid()` below means `auth.uid()`. Every table has `created_at timestamptz default now()`; it is omitted from the lists. Deleting a profile cascades everywhere.

### 5.1 People

| Table | Columns | Access rule |
|---|---|---|
| `profiles` | `user_id uuid pk → auth.users`, `uid bigint identity unique` (wire id), `handle citext unique` (3–20, `[a-z0-9_]`), `display_name text` (1–30), `bio text` (≤160), `avatar_path text`, `home_region text` (free text, e.g. "South Jersey"), `marker_icon text default 'coupe'`, `marker_trail text`, `primary_car_id uuid`, `birth_year int`, `accepted_terms_at timestamptz` | Read: any signed-in user not blocked by the owner. Write: owner. |
| `friendships` | `requester_id`, `addressee_id`, `status` (`pending`, `accepted`), pk on the pair | Read and write: either party. Only the addressee can accept. |
| `blocks` | `blocker_id`, `blocked_id`, pk on the pair | Owner only. |
| `privacy_settings` | `user_id pk`, `friends_level`, `team_level`, `nearby_level` (each `precise`, `approx`, `hidden`; check `nearby_level <> 'precise'`), `ghost_until timestamptz`, `notify_meets_nearby bool`, `notify_radius_km int default 15` | Read: owner. Write: gateway service role only (so it can invalidate its cache). |
| `user_presence_cell` | `user_id pk`, `h3_r7 bigint`, `updated_at` | Service role only. |
| `device_tokens` | `user_id`, `apns_token text`, `environment` (`sandbox`, `production`), pk on (`user_id`, `apns_token`) | Insert, delete, and read own rows: owner (Postgres needs the read to delete by token). Read all: service role. |
| `notifications` | `id uuid pk`, `user_id`, `kind text` (`friend_request`, `friend_accepted`, `like`, `comment`, `mention`, `rsvp`, `meet_changed`, `meet_nearby`, `convoy_invite`, `unlock`, `help_response`), `actor_id uuid null`, `subject_url text` (`waypoints://` path), `title text`, `body text`, `dedupe_key text` (unique per user: one notification per event), `read_at timestamptz` | Read, and update `read_at`: owner. Insert: security-definer `record_notification(...)` only, from triggers and the gateway's `push.Service.Send`. Rows older than 90 days are deleted on insert. Contract change: W7-2 (NTF-6, NTF-7). |

### 5.2 Garage

| Table | Columns | Access rule |
|---|---|---|
| `cars` | `id uuid pk`, `owner_id`, `catalog_variant_id bigint null`, `year int`, `make text`, `model text`, `trim text`, `nickname text`, `color_family text`, `color_hex text`, `paint_name text`, `clearance` (`stock`, `lowered`, `slammed`), `spec_overrides jsonb` (hp, torque, weight, drivetrain, redline, gears), `mods jsonb` (array of mod ids), `sort int` | Read: anyone who can read the owner's profile. Write: owner. |
| `car_photos` | `id`, `car_id`, `path text`, `width int`, `height int`, `sort int` | As `cars`. |
| `build_entries` | `id`, `car_id`, `happened_on date`, `title text` (≤60), `body text` (≤500), `photo_path text`, `mod_id text null` | As `cars`. |

Year, make, model, and trim are copied onto the row as text so a car still renders if the catalog changes.

### 5.3 Map content

| Table | Columns | Access rule |
|---|---|---|
| `reports` | `id`, `author_id`, `kind` (`speed_bump`, `steep_entrance`, `pothole`, `rough_road`, `police`, `hazard`, `closure`, `fuel_e85`), `geom geography(Point)`, `h3_r7 bigint`, `note text` (≤120), `confirmations int default 1`, `expires_at timestamptz`, `permanent bool` | Read: signed-in. Insert, confirm, dismiss: through gateway only. |
| `report_votes` | `report_id`, `user_id`, `still_there bool`, pk on the pair | Service role. |
| `meets` | `id`, `host_id`, `title text` (≤50), `kind` (`meet`, `cruise`, `hangout`, `track_day`, `show`), `geom geography(Point)`, `h3_r7 bigint`, `place_name text`, `starts_at timestamptz`, `ends_at timestamptz`, `details text` (≤500), `visibility` (`public`, `friends`, `team`), `team_id uuid null`, `cancelled_at timestamptz` | Read: per `visibility`. Insert and update: through gateway (host only). |
| `meet_rsvps` | `meet_id`, `user_id`, `status` (`going`, `maybe`), `car_id uuid null`, pk on the pair | Read: anyone who can read the meet. Write: owner. |
| `venue_notes` | `id`, `geom geography(Point)`, `h3_r9 bigint`, `author_id`, `entrance` (`flat`, `moderate`, `steep`), `lot_size` (`small`, `medium`, `large`), `lit bool`, `note text` (≤120) | Read: signed-in. Insert: signed-in. |
| `roads` | `id`, `author_id`, `name text` (≤50), `path geography(LineString)`, `length_m int`, `h3_r7 bigint` | Read: signed-in. Insert: owner. |
| `road_ratings` | `road_id`, `user_id`, `surface int`, `scenery int`, `traffic int` (each 1–5), pk on the pair | Read: signed-in. Write: owner. |
| `spots` | `id`, `spotter_id`, `catalog_model_id bigint`, `year int null`, `make text`, `model text`, `photo_path text`, `city text`, `h3_r5 bigint` | Read: signed-in. Insert: owner. |

Report lifetimes: `police` 45 minutes, `hazard` 2 hours, `closure` 24 hours, extended by each "Still there". `speed_bump`, `steep_entrance`, `fuel_e85` are permanent. `pothole` and `rough_road` last 90 days. Two "Gone" votes with no later "Still there" remove a report.

RPCs (security definer, `stable`): `reports_in_bbox(min_lng, min_lat, max_lng, max_lat)`, `meets_in_bbox(...)` (only meets ending in the future), `roads_in_bbox(...)`, `venue_notes_near(lng, lat, meters)`, `hazards_along(path geography, buffer_m int)` returning reports within the buffer of a route. Rows carry `latitude` and `longitude` instead of raw geography (`roads_in_bbox` returns `path_geojson` plus rating averages; `meets_in_bbox` also excludes cancelled meets and returns `going_count`; `hazards_along` returns `along_m` and orders by it). `h3_*` columns are nullable and written by the gateway; Postgres has no H3 extension.

### 5.4 Teams and messaging

| Table | Columns | Access rule |
|---|---|---|
| `teams` | `id`, `owner_id`, `name text` (≤40), `tag text` (2–5 caps, unique), `about text` (≤300), `icon_path text`, `is_public bool`, `invite_code text unique` | Read: members, or anyone if public. Write: owner or role with `manage_team`. |
| `team_roles` | `id`, `team_id`, `name text`, `color_hex text`, `rank int`, `permissions int` (bitset: `manage_team` 1, `manage_channels` 2, `manage_roles` 4, `kick` 8, `delete_messages` 16, `host_meets` 32) | Read: members. Write: `manage_roles`. |
| `team_members` | `team_id`, `user_id`, `role_id uuid null`, `joined_at`, pk on the pair | Read: members. Insert: self for public teams or with a valid invite code (RPC `join_team(code)`). Delete: self, or `kick`. |
| `channels` | `id`, `team_id`, `name text` (≤30; text channels lowercase with hyphens, voice channels free text), `kind` (`text`, `voice`), `sort int` | Read: members. Write: `manage_channels`. |
| `threads` | `id`, `kind` (`dm`, `listing`), `listing_id uuid null`, `a_id uuid`, `b_id uuid`, unique on (`kind`, `listing_id`, `least(a,b)`, `greatest(a,b)`) | Read and insert: either party, and neither has blocked the other. |
| `messages` | `id bigint identity pk`, `channel_id uuid null`, `thread_id uuid null` (exactly one set), `author_id`, `body text` (≤2000), `attachment_path text`, `deleted_at timestamptz` | Read: channel's team members or thread parties. Insert: same, as self. Soft-delete: author or `delete_messages`. |
| `read_markers` | `user_id`, `channel_id null`, `thread_id null`, `last_read_message_id bigint` | Owner. |

`messages` is in the Supabase Realtime publication. Every team is created with roles "Owner" (all permissions) and "Member" (none), and channels `general` (text) and `Garage` (voice).

### 5.5 Feed, Showdown, Market, Progress, Safety

| Table | Columns | Access rule |
|---|---|---|
| `posts` | `id`, `author_id`, `car_id uuid null`, `video_path text`, `poster_path text`, `caption text` (≤150), `duration_ms int`, `like_count int`, `comment_count int` | Read: signed-in, not blocked. Insert and delete: owner. |
| `post_likes` | `post_id`, `user_id`, pk | Owner; a trigger maintains `like_count`. |
| `post_comments` | `id`, `post_id`, `author_id`, `body text` (≤300) | Read: signed-in. Insert: self. Delete: author or post owner. |
| `follows` | `follower_id`, `followee_id`, pk | Owner. |
| `showdown_entries` | `car_id pk`, `rating int default 1200`, `wins int`, `losses int`, `class` (`street`, `built`, `show`, `classic`) | Read: signed-in. Insert: car owner (requires at least one photo). Rating written only by RPC. |
| `showdown_votes` | `voter_id`, `winner_car_id`, `loser_car_id`, pk on (`voter_id`, `least`, `greatest`) | Insert only through RPC `cast_showdown_vote(winner, loser)`, which applies Elo with K = 24 and rejects a voter's own car. |
| `listings` | `id`, `seller_id`, `kind` (`part`, `car`, `wanted`; for `wanted`, `price_cents` is the budget), `category` (`listing_category` null: `wheels_tires`, `exhaust`, `intake_fuel`, `forced_induction`, `engine`, `drivetrain`, `suspension`, `brakes`, `exterior_aero`, `interior`, `lighting`, `electronics_tuning`, `tools`, `apparel`, `other`; parts and wanted only), `title text` (≤70), `price_cents int`, `condition` (`new`, `used`, `for_parts`), `description text` (≤1500), `fits_make text`, `fits_model text`, `fits_year_from int`, `fits_year_to int`, `car_id uuid null`, `region text`, `h3_r5 bigint`, `status` (`active`, `pending`, `sold`, `removed`) | Read: signed-in. Write: seller. Contract change: W7-6 added `wanted` and `category` (MKT-7, MKT-8). |
| `listing_photos` | `id`, `listing_id`, `path text`, `sort int` | As `listings`. |
| `listing_saves` | `listing_id`, `user_id`, pk | Owner. |
| `achievements` | `user_id`, `key text`, `earned_at`, pk on the pair | Read: anyone. Insert: service role or security-definer triggers. |
| `content_reports` | `id`, `reporter_id`, `target_kind text`, `target_id text`, `reason` (`spam`, `harassment`, `nudity`, `dangerous_driving`, `scam`, `other`), `note text`, `resolved_at` | Insert: self. Read: service role. |
| `race_results` | `id`, `user_id`, `car_id`, `mods jsonb`, `reaction_ms int`, `et_ms int`, `trap_mph_x10 int`, `sixty_ft_ms int`, `input_log bytea` (for ghost replay, ≤4 KB) | Read: signed-in. Insert: owner. |

Storage buckets: `avatars`, `cars`, `posts`, `listings`, `spots`, `teams`, `messages` (public read, owner write under `<user_id>/`), and `catalog` (public read, service write).

---

## 6. Wire protocol

Transport: one WebSocket per client, TLS, binary frames only, per-message deflate off. Path `/v1/rt`. The Supabase access token goes in the first frame, never in the URL.

Schema: `proto/waypoints/v1/realtime.proto`, `syntax = "proto3"`, package `waypoints.v1`. Coordinates are `sfixed32` in units of 1e-7 degrees. Field numbers below are normative.

```proto
message ClientFrame {
  oneof body {
    Hello hello = 1;
    LocationUpdate location = 2;
    SetViewport viewport = 3;
    Ping ping = 4;
    JoinConvoy join_convoy = 5;
    LeaveConvoy leave_convoy = 6;
    RefreshToken refresh_token = 7;
    SetHomeZones home_zones = 8;
  }
}
message Hello          { string access_token = 1; uint32 protocol = 2; string app_version = 3; }
message LocationUpdate { uint32 seq = 1; sfixed32 lat_e7 = 2; sfixed32 lng_e7 = 3;
                         uint32 heading_deg = 4;      // 0–359; 360 = unknown
                         uint32 speed_cms = 5;        // used for server-side rate policy only; never fanned out
                         uint32 accuracy_m = 6; uint64 client_ms = 7; }
message SetViewport    { sfixed32 min_lat_e7 = 1; sfixed32 min_lng_e7 = 2; sfixed32 max_lat_e7 = 3; sfixed32 max_lng_e7 = 4; }
message Ping           { uint64 client_ms = 1; }
message JoinConvoy     { string convoy_id = 1; }
message LeaveConvoy    {}
message RefreshToken   { string access_token = 1; }
message SetHomeZones   { repeated Zone zones = 1; }
message Zone           { sfixed32 lat_e7 = 1; sfixed32 lng_e7 = 2; uint32 radius_m = 3; }

message ServerFrame {
  oneof body {
    Welcome welcome = 1;
    Batch batch = 2;
    Pong pong = 3;
    Error error = 4;
    ConvoyState convoy = 5;
    MapEvent map_event = 6;
  }
}
message Welcome { uint64 uid = 1; uint64 server_ms = 2; uint32 tick_ms = 3; string node = 4; }
message Batch {
  uint64 server_ms = 1;
  repeated EntityUpdate updates = 2;
  repeated uint64 gone = 3;                // uids that left view, went hidden, or went offline
  repeated CellAggregate aggregates = 4;   // sent instead of updates when the viewport is too large
}
message EntityUpdate {
  uint64 uid = 1;
  sfixed32 lat_e7 = 2; sfixed32 lng_e7 = 3;
  uint32 heading_deg = 4;                  // 360 when approximate
  Tier tier = 5;
  uint32 age_ds = 6;                       // tenths of a second since the publisher's fix, at flush time
  uint64 origin_ms = 7;                    // publisher's client_ms; set only when the server runs with -bench
  optional EntityInfo info = 8;            // present on first appearance and when it changes
}
enum Tier { TIER_UNSPECIFIED = 0; PRECISE = 1; APPROX = 2; }
enum Relation { RELATION_UNSPECIFIED = 0; FRIEND = 1; TEAMMATE = 2; CONVOY = 3; NEARBY = 4; }
message EntityInfo { Relation relation = 1; string marker_icon = 2; string marker_trail = 3;
                     uint32 paint_rgb = 4; string display_name = 5; string car_label = 6; }
                     // display_name and car_label are empty for NEARBY
message CellAggregate { uint64 h3 = 1; uint32 count = 2; }
message Pong   { uint64 client_ms = 1; uint64 server_ms = 2; }
message Error  { Code code = 1; string message = 2;
                 enum Code { CODE_UNSPECIFIED = 0; UNAUTHORIZED = 1; BAD_FRAME = 2; RATE_LIMITED = 3;
                             SLOW_CONSUMER = 4; PROTOCOL_VERSION = 5; SHUTTING_DOWN = 6; } }
message ConvoyState { string convoy_id = 1; uint64 leader_uid = 2; repeated uint64 member_uids = 3;
                      optional Destination destination = 4; bytes route_polyline = 5; // Google polyline, precision 5
                      optional Regroup regroup = 6; bool ended = 7; }
message Destination { sfixed32 lat_e7 = 1; sfixed32 lng_e7 = 2; string name = 3; }
message Regroup     { sfixed32 lat_e7 = 1; sfixed32 lng_e7 = 2; uint64 set_ms = 3; }
message MapEvent { Kind kind = 1; string id = 2; Op op = 3; sfixed32 lat_e7 = 4; sfixed32 lng_e7 = 5; string subtype = 6; string title = 7;
                   enum Kind { KIND_UNSPECIFIED = 0; REPORT = 1; MEET = 2; }
                   enum Op { OP_UNSPECIFIED = 0; UPSERT = 1; REMOVE = 2; } }
```

Rules:

- Two delivery lanes per connection. **Conflated lane**: `EntityUpdate`s, keyed by uid, newest overwrites, flushed as one `Batch` per tick. **Reliable lane**: `Welcome`, `Error`, `ConvoyState`, `MapEvent`, `gone` lists; bounded queue of 64 frames; overflow closes the connection with `SLOW_CONSUMER` (close code 4008) and the client reconnects.
- No replay log. On connect or reconnect the client sends `Hello`, `SetHomeZones`, `SetViewport`, and `JoinConvoy` if applicable, and the server answers with a `Batch` containing current state. Location is conflatable, so resuming from "now" is correct.
- Server-side rate limit: `LocationUpdate` more often than every 400 ms is dropped silently. Twenty malformed frames in a minute closes with `BAD_FRAME`.
- Expected size: about 22 bytes per `EntityUpdate` without `info`. The old JSON event was about 190 bytes.

HTTP JSON API on the gateway (all require `Authorization: Bearer <Supabase access token>`):

| Method and path | Body | Effect |
|---|---|---|
| `GET /healthz` | | 200 when serving. No auth. |
| `GET /metrics` | | Prometheus text. Bound to a separate port. |
| `PUT /v1/privacy` | `{friends_level, team_level, nearby_level, ghost_until, notify_meets_nearby, notify_radius_km}` | Writes `privacy_settings`, invalidates caches on all nodes. |
| `POST /v1/reports` | `{kind, lat, lng, note}` | Inserts, publishes `MapEvent` to the cell. Merges with an existing report of the same kind within 30 m (counts as a confirmation). |
| `POST /v1/reports/{id}/vote` | `{still_there}` | Applies section 5.3 rules; publishes `UPSERT` or `REMOVE`. |
| `DELETE /v1/reports/{id}` | | Author only, within 5 minutes of posting (M5 Undo). Publishes `REMOVE`. |
| `POST /v1/meets` | meet fields | Inserts, publishes `MapEvent`, pushes to users whose `user_presence_cell` is within their own `notify_radius_km`. Limit: 3 per user per day. |
| `PATCH /v1/meets/{id}`, `DELETE /v1/meets/{id}` | | Host only. Publishes; pushes RSVP'd users on time change or cancel. |
| `POST /v1/convoys` | `{name, destination?}` | Returns `{id, join_code}`. |
| `POST /v1/convoys/join` | `{join_code}` | Returns convoy. |
| `PUT /v1/convoys/{id}/destination`, `PUT /v1/convoys/{id}/regroup`, `DELETE /v1/convoys/{id}` | | Leader only. |
| `POST /v1/convoys/{id}/invite` | `{user_ids}` | Members only. Pushes the join code (convoy invites switch in S3). |
| `POST /v1/voice/token` | `{channel_id}` or `{convoy_id}` (exactly one) | Channel: checks team membership; returns `{url, token}` for LiveKit room `ch_<channel_id>`. Convoy: current convoy members only (package `convoy`'s state, Postgres mirror); room `cv_<convoy_id>`, participant identity is the realtime uid. A member leaving is removed from the room and the room is deleted when the convoy ends (LiveKit RoomService). 403 when not a member. |
| `POST /internal/notify` | `{kind, ...}` | Called by a Postgres trigger through `pg_net` with a shared secret header; sends pushes for DMs, mentions, friend requests. The trigger has already written the `notifications` rows (W7-2), so the gateway only pushes; gateway-originated notes (meets nearby, meet changes, convoy invites) are recorded by `Send`. Meets nearby is capped at three per person per 24 hours (NTF-7). |

---

## 7. Realtime gateway design

### 7.1 Keep the TypeScript service or rewrite it?

Rewrite, in Go.

What existed (latest version, GitHub `main` as of 2026-08-17): a Fastify and `ws` service. Rooms keyed by a join code, capped at 50 participants, JSON text frames, one process, every location update appended to a per-room event log and broadcast to the whole room, with heartbeat-backed presence and a safety layer (SOS, arrival ping). It was competently hardened for what it was: a session-indexed fan-out, a circular event buffer, per-IP join limits, and a real load test. There was no geography, no public map, no per-viewer privacy, no per-connection backpressure, and no way to use a second core or a second node.

Its measured numbers are the baseline this rewrite is compared against (from the deleted `docs/CAPACITY.md`; Apple M2, Node 24, client and server on one host, 20 s runs):

| Sessions × participants | Clients | Deliveries per second | p50 | p99 |
|---|---|---|---|---|
| 1 × 20 | 20 | 361 | 9.5 ms | 23.0 ms |
| 5 × 10 | 50 | 427 | 12.1 ms | 21.3 ms |
| 20 × 10 | 200 | 1,709 | 27.7 ms | 37.1 ms |

Benchmark I (package W2-6) must include a scenario shaped like the last row (200 clients in groups of 10, 1 Hz) on the same Mac so the before-and-after comparison is like for like, before moving to the larger scenarios the old service could not attempt.

Why not harden it: the new product needs a different system (interest management by map cell, per-viewer privacy tiers, conflation, binary frames, multi-node). None of the old hot path survives that, so "harden" would mean a rewrite in place, on a runtime with one event loop where using more cores means running more processes and inventing a bus between them on day one.

Why Go, against the goal of a concurrency-first resume project:

- The concurrency is in the code, not hidden in a framework: one read and one write goroutine per connection, shard goroutines that own their state, bounded channels, explicit conflation. That is the thing to show.
- It is measurable with what ships in the toolchain: `pprof`, the race detector (`go build -race` during development), execution traces.
- Go 1.27 is already installed on the owner's machine. Protobuf and NATS are first-class.
- Agents write correct Go reliably and the build is seconds.

Alternatives considered:

- **Rust (tokio)**: strongest tail-latency claim because there is no garbage collector. Rejected: with per-connection state this small (a conflation map and a 64-slot queue) Go's collector pauses are well under a millisecond and the network dominates; Rust would cost iteration speed for a difference the benchmark would not show. If benchmark III shows collector pauses in p99.9, that finding goes in the write-up honestly.
- **Swift on server (Hummingbird)**: one language end to end. Rejected: thin ecosystem for this workload and no credible high-connection WebSocket numbers to compare against.
- **Elixir/Phoenix**: Channels and Presence would do most of this out of the box. Rejected for exactly that reason: the framework would be doing the engineering.
- **Node with uWebSockets.js**: enough for the real load. Rejected: weakest concurrency story.

### 7.2 Process layout

```
          accept
            │
   ┌────────▼────────┐  one per connection
   │ reader goroutine│──decode──▶ rate limit ──▶ privacy.Resolve ──▶ hub.Publish(cell, update)
   └─────────────────┘                                                     │
                                                           hash(cell) % S  ▼
   ┌─────────────────┐                                         ┌──────────────────────┐
   │ writer goroutine│◀── tick (100 ms) drains ◀── outbox ◀────│ shard goroutine × S  │
   └─────────────────┘        conflated map + reliable queue   │ owns: cell→subs map, │
                                                               │ last-known per cell  │
                                                               └──────────────────────┘
```

- **Shards**: `S = 2 × GOMAXPROCS` goroutines. Each owns, with no locks, the subscriber sets and last-known publisher positions for the cells that hash to it. Commands (`subscribe`, `unsubscribe`, `publish`, `snapshot`) arrive on a bounded channel (capacity 4,096). If a shard's channel is full, `publish` commands for location are dropped and counted (`hub_publish_dropped_total`); subscribe and unsubscribe block. Location is the only thing allowed to be dropped.
- **Outbox** (per connection): a mutex guarding `map[uid]EntityUpdate` plus a dirty flag, and a separate buffered channel of 64 for the reliable lane. A shard writes into an outbox under that mutex and never touches the socket. The mutex is held for a map assignment only. This is the one place a lock is used; a lock-free design was considered and left out because the critical section is a few nanoseconds and per-connection.
- **Writer**: wakes on a ticker (default 100 ms, `-tick=0` means wake on every dirty signal), swaps the map out, encodes one `Batch`, writes with a 5 s deadline. A missed deadline closes the connection.
- **Reader**: decodes, enforces rate limits, calls `privacy.Resolve` to produce the representations (7.4), publishes.

### 7.3 Interest management

- Cells are H3 resolution 7 (average edge 1.4 km, area 5.2 km²).
- A publisher is in exactly one cell. Moving to a new cell sends `gone` to subscribers of the old cell that are not subscribed to the new one.
- **Viewport subscription**: on `SetViewport` the gateway computes the covering set of resolution 7 cells plus one ring. If the set is 64 cells or fewer, the connection subscribes to them and gets individual entities. If larger, it subscribes at resolution 5 (about 250 km² per cell) and receives `CellAggregate` counts once per second; over 64 cells at resolution 5 it receives nothing but friends.
- **Friend and team subscription**: independent of viewport. At `Hello` the gateway loads the user's accepted friends and teammates and subscribes the connection to subject `u.<uid>` for each (cap 1,000).
- **Convoy**: subject `c.<convoy_id>`.
- **De-duplication**: a friend inside the viewport arrives on both `u.<uid>` and the cell. The outbox keeps the higher tier.

### 7.4 Privacy resolution

For each accepted `LocationUpdate` the reader computes, from cached settings:

| Output | Published to | Condition |
|---|---|---|
| Precise update | `u.<uid>.p` | Friends level is Precise, not ghost, not in a home zone |
| Approximate update (res 8 centre, no heading, at most every 15 s) | `u.<uid>.a` | Any audience is Approximate or capped to it |
| Nearby update (same approximate form, `Relation NEARBY`, no name) | cell subject `cell.<h3r7>` | Nearby level is Approximate, not ghost, not in a home zone |
| Convoy update (precise) | `c.<id>` | In a convoy |

A subscriber to a user is attached to `.p` or `.a` according to that publisher's setting for the subscriber's relation, decided at subscribe time and re-decided when the publisher's settings change (invalidation message on subject `acl.<uid>`). Settings are loaded from Postgres at `Hello` and cached in memory; `PUT /v1/privacy` is the only writer, so the cache is exact.

### 7.5 Presence and snapshots

- Presence is derived, not stored: a user is live if their node has seen an update or ping in the last 40 s.
- When a connection subscribes to a cell or user, the owning shard replies with the last-known update for each live publisher it holds. Across nodes this is a NATS request on `who.cell.<h3>` or `who.u.<uid>` with a 50 ms collection window; nodes holding matching publishers reply.
- Every 60 s and on disconnect, the gateway writes `user_presence_cell` in batches (one statement per flush, at most one flush per second). This is the only database write caused by location.

### 7.6 Scaling out

- Any node serves any client; the load balancer needs no stickiness.
- `bus.Bus` interface: `Publish(subject, bytes)`, `Subscribe(subject, handler)`, `Request(subject, bytes, window)`. Single-node mode uses an in-process implementation with zero serialization. Multi-node mode uses NATS core.
- A node subscribes on NATS only to subjects that have at least one local subscriber, and unsubscribes when the count reaches zero. NATS propagates interest between servers, so an update for a cell nobody is watching anywhere is dropped at the publisher's node.
- Payload on the bus is a compact JSON envelope (`hub/bridge.go`) carrying the update and the publisher's current policy, so a receiving node can apply privacy exactly as the publisher's node does. *(Implementation note: the plan first proposed pre-encoded `EntityUpdate` bytes; those cannot carry the policy the receiving shard needs.)*
- At-most-once is correct for conflatable data. Reliable-lane messages (`MapEvent`, `ConvoyState`) are also published once; a client that missed one reconciles on the next camera-settle fetch or convoy snapshot.
- Convoy state lives in memory on the node that created it and is mirrored to Postgres table `convoys` (added by package W2-1's migration) on each change, so any node can load it.

### 7.7 Left out of the gateway

Redis (NATS covers the bus and nothing needs a cache server), JetStream or any durable log (nothing replayable), consistent-hash routing of users to nodes (interest-based pub/sub removes the need), CRDT presence (TTL presence is enough off the BEAM), WebTransport or QUIC (no native Swift client API confirmed; fast reconnect covers network handoff), per-connection entity handle tables (the numeric `uid` already makes updates small; revisit only if benchmark III shows bytes are the bottleneck), an epoll reactor in place of goroutine-per-connection (only pays off far beyond the target connection counts).

---

## 8. Performance targets and benchmark

### 8.1 Targets

Reference machine: 2 vCPU, 8 GB (half of an Oracle Cloud Always Free Ampere A1 allocation, section 14; if that is unavailable, the owner's Mac with the load generator on the same machine, labelled as loopback).

| Metric | Target |
|---|---|
| Concurrent connections per node, idle with heartbeats | 50,000, under 2.5 GB resident |
| Memory per connection | under 50 KB |
| Active publishers at 1 Hz with mean fan-out 20 | 5,000 (100,000 deliveries per second) |
| Fan-out latency, tick 100 ms: publisher's send to subscriber's receive | p50 ≤ 60 ms, p99 ≤ 150 ms, p99.9 ≤ 250 ms |
| Fan-out latency, immediate mode | p50 ≤ 5 ms, p99 ≤ 40 ms |
| Slow-consumer isolation: 5% of subscribers stop reading | healthy subscribers' p99 moves by under 10%; stalled ones are closed within 6 s |
| Two nodes with NATS vs one node, same total load | p99 increases by under 10 ms |
| Reconnect storm: 10,000 connections drop and return within 10 s | all live again within 15 s; no node restart |
| Bytes per delivered update on the wire | under 30, against roughly 190 for the old JSON |

These are targets, not claims. The benchmark report states what was measured, on what, and where a target was missed.

### 8.2 Load generator (`server/cmd/loadgen`)

- Go, one process acting as all publishers and all subscribers so a single monotonic clock covers both ends.
- Open-loop: publishers send on a fixed schedule. Latency is measured from the *scheduled* send time, so a stalled generator cannot hide delay (avoids coordinated omission).
- The gateway runs with `-bench`, which copies the publisher's `client_ms` into `EntityUpdate.origin_ms`. The generator records `receive time − origin` into an HDR histogram (1 µs to 60 s, 3 significant digits).
- Auth: `-bench` also accepts HS256 tokens signed with a local secret so the run does not depend on Supabase. That flag refuses to start unless `WAYPOINTS_ENV=bench`.
- Scenario file (YAML): connection count, publisher fraction, movement model (random walk along a grid at 15 m/s inside a bounding box sized to give the target mean fan-out), viewport size, stalled-reader fraction, ramp, duration.
- For more than about 28,000 connections from one source address, the generator binds across multiple source IPs (`127.0.0.2`… on loopback, or secondary private addresses on the VM).
- Output: JSON with p50, p90, p99, p99.9, max, deliveries per second, bytes per delivery, plus the gateway's CPU, resident memory, goroutine count, and drop counters scraped from `/metrics`.

### 8.3 Phases

| Phase | Package | Produces |
|---|---|---|
| I | W2-6 | Single node, in-process bus, loopback on the Mac. Tick vs immediate. First numbers in `docs/BENCHMARKS.md`. |
| II | W3-5 | Two nodes plus NATS. Slow-consumer and reconnect-storm scenarios. |
| III | W5-6 | The full matrix on the reference VM with generator on a second VM. Final table, flame graph, and a short "what limited it" analysis in `docs/BENCHMARKS.md`, summarized in `README.md`. |

Each phase commits raw result JSON under `bench/results/<date>/` so every published number is traceable.

---

## 9. Design system

Module `DesignSystem`. Every value below becomes a named token; feature code never writes a literal color, font size, radius, duration, or spacing number.

### 9.1 Idea

A parking lot at night under sodium lights, read through an instrument cluster. Warm graphite surfaces, one amber accent, numbers set like gauge readouts, and the only saturated colors on screen are the paint of people's cars.

Dark only. The app is used at night, in cars, over a dark map, and a second theme would double the surface to get right. `preferredColorScheme(.dark)` at the root.

The test applied to every element: does it work, and would the screen be worse without it? If the answer to the second is no, it is not in this plan and must not be added during implementation.

### 9.2 Color

| Token | Hex | Use |
|---|---|---|
| `asphalt` | `#0D0D0E` | App background. |
| `tarmac` | `#161617` | Sheets, grouped rows, bars. |
| `concrete` | `#202022` | Inputs, raised rows, image placeholders. |
| `curb` | `#2B2B2E` | Pressed and selected fills. |
| `seam` | `#37373B` | Hairlines, 1 physical pixel. |
| `chalk` | `#F3F1EC` | Primary text and icons. |
| `dust` | `#A8A6A0` | Secondary text. |
| `gravel` | `#94928D` | Tertiary text, disabled. Never below this for text. (W0-D audit: lifted from `#86847F`, which measured 4.35:1 on `concrete` and 3.78:1 on `curb`.) |
| `sodium` | `#FFB224` | The accent. Primary action, the route line, your own marker ring, selection, live navigation. |
| `sodiumDim` | `#3A2A0A` | Tinted fill behind sodium text or icon. |
| `brake` | `#FF4B3A` | Destructive actions, errors, hazards and closures on the map, live recording. |
| `go` | `#34D17C` | Live presence, "Going", success confirmation. |
| `xenon` | `#BFE2FF` | Informational: approximate-location ring, links, voice-speaking ring. |

Rules:

- One accent. `sodium` appears at most once per screen as a filled control. If two things want to be amber, one of them is not the primary action.
- Text on `sodium` fills is `asphalt`, never white.
- `brake`, `go`, and `xenon` are states, not decoration. Each always travels with a shape or word so it survives color blindness.
- Paint colors (a user's `color_hex`) appear only inside vehicle silhouettes and as a 3 pt bar on car rows.
- No gradients anywhere except two functional ones: a scrim under text on video and photos (`asphalt` 0% to 70%, bottom 35% of the frame), and the fade at the edge of a horizontally scrolling strip.
- W0-D must check every text and glyph pair against WCAG (4.5:1 for text under 18 pt, 3:1 above and for glyphs) and adjust lightness within a token if one fails, recording the final value here.

### 9.3 Type

Three voices.

| Voice | Face | Where |
|---|---|---|
| Text | SF Pro (system) | Everything read as language. |
| Display | SF Pro Expanded (`.fontWidth(.expanded)`), semibold or bold | Screen titles, section labels, tab titles are not included (the tab bar uses system). |
| Readout | B612 Mono Bold (SIL OFL, embedded; fall back to SF Mono Bold if the font file cannot be bundled) | Numbers that are measurements: speed, distance to turn, ETA, horsepower, torque, times, prices, counts on rankings. |

Scale. Each token maps to a Dynamic Type style and scales with it.

| Token | Face | Size / leading at default | Relative to | Use |
|---|---|---|---|---|
| `display` | Display bold | 28 / 32 | `.title` | Screen titles on root screens. |
| `title` | Display semibold | 20 / 24 | `.title3` | Sheet titles, card titles, car names. |
| `label` | Display semibold, uppercase, tracking +6% | 11 / 13 | `.caption2` | Section labels ("NEARBY", "TIMELINE"). |
| `body` | Text regular | 17 / 22 | `.body` | Default. |
| `bodyStrong` | Text semibold | 17 / 22 | `.body` | Row titles, names. |
| `sub` | Text regular | 15 / 20 | `.subheadline` | Secondary lines. |
| `foot` | Text regular | 13 / 18 | `.footnote` | Metadata, timestamps. |
| `readoutXL` | Readout | 56 / 56 | `.largeTitle` | Speed, quarter-mile time. |
| `readoutL` | Readout | 32 / 34 | `.title` | Horsepower, torque, next-turn distance. |
| `readoutM` | Readout | 17 / 22 | `.body` | Inline stats, prices. |
| `readoutS` | Readout | 12 / 16 | `.caption` | Marker labels, units. |

Rules: sentence case everywhere except `label`. No exclamation marks. Units are set in `readoutS` `dust` after the number with a thin space ("412 hp"). Numbers that change animate with `.contentTransition(.numericText())`. Maximum two voices in one row.

### 9.4 Spacing, shape, depth

- **Spacing** tokens: 2, 4, 8, 12, 16, 20, 24, 32, 48. Screen side margin is 20. Row vertical padding 12. Gap between unrelated groups 32. Use `@ScaledMetric` for anything that must grow with text.
- **Radii**: `r6` (chips, small thumbnails), `r12` (inputs, rows, buttons), `r20` (media, cards over the map), `r28` (top corners of sheets). Capsules only for the speed readout pill and marker labels. Nested corners are concentric: inner radius = outer radius − padding.
- **Depth**: surfaces separate by fill step (`asphalt` → `tarmac` → `concrete`) and a `seam` hairline. No shadows on content. Only things floating over the map cast a shadow: y 4, blur 16, black 45%.
- **Material**: controls and the sheet over the map use `.regularMaterial`. Nothing else is translucent.
- **Lists are rows, not cards.** A row is full-width with a `seam` divider inset to the text edge. A card (a `tarmac` box with `r20`) is allowed only when the item is a self-contained object the user picks up as a whole: a car in the garage, a listing in the market grid, a meet floating over the map.
- **Minimum hit target** 44 × 44 pt, including markers.

### 9.5 Motion

| Token | Curve | Use |
|---|---|---|
| `quick` | `.snappy(duration: 0.22, extraBounce: 0)` | Presses, toggles, chip selection, row highlight. |
| `standard` | `.smooth(duration: 0.35)` | Content changes, expanding rows, tab content. |
| `sheet` | `.spring(duration: 0.45, bounce: 0.12)` | Sheet detents, peek cards rising from a marker. |
| `travel` | `.linear(duration: <interval between fixes>)` | A marker moving between two position fixes, so motion is continuous. |
| `camera` | MapKit camera animation, 0.6 s | Recenter, focus on selection. |
| `win` | `.bouncy(duration: 0.5, extraBounce: 0.1)` | Only three places: the Showdown winner settling, a spot joining the collection, a marker icon unlocking. |

Rules: every animation starts from the thing the user touched (zoom transitions from the tapped thumbnail via `matchedTransitionSource` and `.navigationTransition(.zoom)`). Nothing loops except the live ring on a moving marker and the voice-speaking ring. With Reduce Motion on, every transition becomes a 0.2 s crossfade, markers jump, loops stop.

### 9.6 Haptics

Through `.sensoryFeedback`, defined once in `DesignSystem.Haptic`.

| Token | Feedback | Fires on |
|---|---|---|
| `tick` | `.selection` | Moving through picker values, year strip, mod toggles, shift points on the dyno scrub. |
| `tap` | `.impact(weight: .light)` | Selecting a marker, sending a message. |
| `set` | `.impact(flexibility: .soft)` | Sheet reaching a detent, a swipe card passing its commit threshold. |
| `thud` | `.impact(weight: .heavy)` | Showdown choice committed, race launch. |
| `done` | `.success` | Report posted, meet created, listing published, RSVP saved. |
| `warn` | `.warning` | Off route, hazard ahead (navigation only). |
| `fail` | `.error` | A submit that failed. |

Never on things that happen remotely (a friend arriving, a message received) and never on scroll.

### 9.7 Icons

- Interface icons: SF Symbols, weight `.medium` in content, `.semibold` in the tab bar, hierarchical rendering, never multicolor. One symbol means one thing across the app (list in `DesignSystem/Symbols.swift`).
- No emoji in interface text or as icons. Users can type emoji in their own messages.
- Car makes are written as text. No manufacturer logos or badges anywhere (trademark, App Review 5.2.1).

### 9.8 Map icon set

Hand-drawn vectors owned by `DesignSystem/MapIcons/`, shipped as template PDFs or SVGs in an asset catalog and drawn through one view, `VehicleMarker`.

**Vehicle silhouettes.** Top-down, nose up, on a 24 × 24 grid, filled, no interior detail. Types are told apart by proportion: length, roofline, overhangs, wing.

- Free from the start (16): `coupe`, `sedan`, `hatch`, `wagon`, `roadster`, `muscle`, `pony`, `supercar`, `kei`, `pickup`, `suv`, `van`, `classic`, `hot_rod`, `sport_bike`, `cruiser_bike`.
- Earned (20): `time_attack` (big wing), `drift` (wing and wide rear), `rally` (roof scoop, mud flaps), `lowrider`, `lifted_truck`, `dually`, `wide_body`, `fastback_classic`, `woody_wagon`, `microcar`, `van_camper`, `ute`, `shooting_brake`, `targa`, `gt_wing_hatch`, `rat_rod`, `restomod`, `box_truck`, `flatbed` (carrying a car), `safety_car` (light bar).
- **Trails** (earned, 8): a short mark behind a moving marker: `none`, `dash`, `double`, `chevrons`, `dots`, `checker`, `tread`, `comet`. Single color (`chalk` at 50%), no particles.

How icons are earned (never bought, never for speed or distance):

| Key | Requirement | Unlocks |
|---|---|---|
| `first_meet` | RSVP "Going" and be within 200 m of a meet during it | `lowrider` |
| `host_3` | Host 3 meets with at least 5 attendees who checked in | `safety_car` |
| `reports_10` | 10 of your reports confirmed by others | `rally` |
| `reports_50` | 50 confirmed | `lifted_truck` |
| `spots_25` / `spots_100` | Spot 25 / 100 distinct models | `shooting_brake` / `woody_wagon` |
| `roads_5` | Rate 5 roads | `targa` |
| `build_10` | 10 timeline entries on one car | `restomod` |
| `showdown_top10` | A car in the weekly top 10 of its class | `wide_body` |
| `convoy_lead` | Lead a convoy of 5 or more to its destination | `flatbed` |
| `strip_12s` / `strip_10s` | Virtual quarter mile under 12 s / 10 s | `drift` / `time_attack` |

The rest of the earned set and the trails are assigned to further keys by package W5-5 following the same rule: participation, never speed.

**Marker anatomy** (`VehicleMarker`):

| State | Appearance |
|---|---|
| You | 44 pt. Silhouette filled with your paint color, 2 pt `asphalt` keyline, 2 pt `sodium` ring. Rotates to heading above 8 km/h; below that it keeps its last heading. |
| Friend, precise | 40 pt. Paint fill, `asphalt` keyline, thin `chalk` inner stroke. Name below in a `tarmac` capsule (`readoutS`). A `go` ring pulses once per 2 s while moving. |
| Friend or teammate, approximate | 40 pt silhouette at 60% opacity inside a dashed `xenon` circle 56 pt wide, no rotation. Label "near <place>" when selected. |
| Nearby stranger | 28 pt, `dust` fill (no paint color), no label, no rotation. Tap target 44 pt. |
| Stale | Over 60 s without a fix: ring stops. Over 5 min: 50% desaturated, label gains "5 m". Over 30 min: removed. |
| Cluster | `tarmac` circle 44 pt with count in `readoutM`; the two highest-priority silhouettes peek from behind. You and a selected friend never cluster. |
| Selected | Scales to 1.15 with `sheet`; the peek card rises from it. |

**Report glyphs** (24 pt glyph in a 32 pt badge; badge shape encodes severity so color is not the only signal): diamond `brake` for `hazard`, `closure`, `pothole`; circle `sodium` outline for `speed_bump`, `steep_entrance`, `rough_road`; square `xenon` for `police`; circle `go` for `fuel_e85`. Glyphs are custom drawings in the same stroke weight as the silhouettes.

**Meet pins**: a `tarmac` rounded square (r12) 40 pt with a custom glyph per kind (`meet`: three cars nose-in; `cruise`: a curved road; `hangout`: a cup; `track_day`: a chicane; `show`: a rosette), and the start time below in `readoutS`. A meet happening now has a `go` edge.

### 9.9 Components

Built once in `DesignSystem`, each with a preview. Feature packages may not build their own version.

| Component | Behaviour |
|---|---|
| `PrimaryButton` | 52 pt tall, `r12`, `sodium` fill, `asphalt` label in `bodyStrong`. Pressed: 96% scale, `quick`. Loading: label is replaced by a 3-dot stepped indicator; width does not change. Disabled: `curb` fill, `gravel` label. |
| `SecondaryButton` | Same size, `concrete` fill, `chalk` label. |
| `QuietButton` | Text only, `sodium`. For the lesser of two actions. |
| `DestructiveButton` | `concrete` fill, `brake` label. Always followed by a confirmation dialog naming what will be lost. |
| `IconButton` | 44 pt, symbol only, always with an accessibility label. Over the map: `.regularMaterial` circle with the map shadow. |
| `Row` | Leading slot (avatar, thumbnail, or symbol), title, optional subtitle, trailing slot (value, chevron, toggle). 56 pt minimum. |
| `SectionLabel` | `label` text in `dust`, 32 above, 8 below. |
| `Field` | `concrete` fill, `r12`, 52 pt. The label sits above in `foot` `dust`. Error text below in `brake` says what to do. Character count appears only within 10 of the limit. |
| `Chip` | 32 pt, `r6`, `concrete`; selected: `sodiumDim` fill with `sodium` text. Used only for filters and single-choice sets of five or fewer. |
| `SegmentedSwitch` | Up to three options, underline indicator that slides with `quick`. |
| `Avatar` | Circle, sizes 28, 40, 64, 96. Missing photo: initials on `curb`. |
| `CarBadge` | Silhouette in paint color plus "2019 Mustang GT" in `sub`. The standard way to mention a car inline. |
| `Readout` | Number in a readout token with unit, optional `label` above, optional low–high range shown as a thin bar beneath. |
| `MediaView` | Image with `concrete` placeholder, crossfade 0.2 s on load, tap to open full screen with zoom transition. |
| `Sheet` | Wrapper that applies `r28`, `tarmac`, drag indicator, and title row. |
| `Banner` | A single line pinned under the navigation bar for connection state. Offline: `concrete` with "Offline. Showing what was saved." Reconnecting: "Reconnecting". Dismisses itself. |
| `EmptyState` | One sentence of what is absent and one button that fixes it. No illustration. |
| `ErrorState` | What failed in plain words, and "Try again". |
| `Skeleton` | Loading placeholder matching the final layout's blocks in `concrete`. No shimmer. Shown only if loading exceeds 300 ms. |
| `Toast` | Bottom, above the tab bar, 3 s, for completed actions that leave the screen ("Report posted"). With "Undo" where undo is possible. |

`DesignSystem` also ships a `Gallery` view, reachable from Settings in debug builds, showing every token and component.

### 9.10 Voice and copy

- Say the thing. "Add your car", not "Get started". "Couldn't post. Check your connection and try again.", not "Oops".
- Use the scene's own words: meet, cruise, build, convoy, team, spot, run, strip. Never "content", "experience", "community members".
- Buttons are verbs that say what happens: "Start meet", "Post report", "Join convoy", "List it".
- Second person, present tense. No first person from the app.
- Empty states name the fix: "No friends on the map yet." with a button "Invite a friend".
- Every estimate carries the word "est." and a range. Never a bare number that looks measured.
- All strings live in a String Catalog (`Localizable.xcstrings`) per module. English only for now.

### 9.11 Patterns that are banned

Implementers fall back on these by habit. Do not.

- Purple, indigo, or blue-to-purple anything. Gradient fills, gradient text, glow or neon shadows, blurred color blobs behind content.
- Emoji as icons or in headings.
- Card grids as the default layout. Cards nested in cards. Stat tiles in a row of three.
- Pill badges on everything. Colored status dots without a word next to them. A colored stripe down the left edge of a block.
- Uniform soft drop shadows on content.
- Centered text blocks outside of empty states and the sign-in screen.
- A default `Form` or grouped `List` appearance. Lists use `Row` on `asphalt`.
- Onboarding carousels, feature tours, confetti, mascots, illustrations of people.
- Copy: "Welcome back", "Get started", "Oops", "Something went wrong" alone, "Seamless", "Unlock", "Level up", "Let's go", "Awesome", Title Case Buttons, exclamation marks, three-adjective taglines.
- Placeholder people or cars: no "John Doe", no "Car 1". Previews use real model names and plausible handles.
- Spinners centered on an empty screen. Use `Skeleton`.
- A control that does nothing yet. If its feature is not built, the control is not on screen.
- More than five tabs, a hamburger menu, a floating action button that opens a radial menu.

### 9.12 Accessibility

Dynamic Type to AX5 without truncating primary text (rows grow, readouts wrap their unit). VoiceOver labels on every control and marker ("Maya, 2 miles north east, moving"). Map content is also reachable as a list in the map sheet. Differentiate Without Color and Increase Contrast honored through the token layer. Reduce Motion as in 9.5.

---

## 10. Screens

Conventions for this section:

- "Sheet" means the `Sheet` component. Detents are given as heights or `medium`/`large`.
- Unless a screen says otherwise: loading shows `Skeleton` after 300 ms; a failed load shows `ErrorState` with "Try again"; offline shows the `Banner` and cached data if any; a submit that fails keeps everything the user typed, shows the reason under the button, and fires `fail`.
- Every user, post, message, listing, meet, and report has "Report" and (for users) "Block" in its overflow menu, opening X1.
- Copy in quotes is final.

### 10.1 App structure

Five tabs. Each exists because it is a different job the user arrives to do.

| Tab | Label | Symbol | Why it is a tab |
|---|---|---|---|
| 1 | Map | `map` | Who is out, what is happening, how to get there. The home screen. |
| 2 | Feed | `play.rectangle` | Watching. Showdown lives here as a mode because it is also lean-back judging of builds. |
| 3 | Market | `tag` | Buying and selling. A different intent from socializing; burying it would kill it. |
| 4 | Teams | `person.3` | Conversation: team channels, voice, and direct messages. |
| 5 | Garage | `car.side` | Your cars and your profile, the mod simulator, the strip. |

System `TabView` with an opaque `tarmac` bar and a `seam` top hairline. Selected item `sodium`, others `dust`. A tab is hidden until its feature reports `isAvailable`. An unread count appears on Teams only (a number, `brake` fill). Tapping the current tab pops to its root; tapping Map again recenters on you.

Profile is not a tab. Your own profile is the top of Garage; other people's open by route from anywhere.

### 10.2 Onboarding

**O1 Sign in.** Purpose: get an account with the least typing.
- Layout: `asphalt`. Wordmark "Waypoints" in `display`, upper third, left-aligned at the margin. Under it one line in `body` `dust`: "See who's out. Find the meet. Show the build." Bottom: `Sign in with Apple` (system button, white style), then `SecondaryButton` "Continue with email". Below, `foot` `gravel`: "By continuing you agree to the Terms and Privacy Policy." with both words linked.
- Email path: a `Field` for the address, `PrimaryButton` "Send code", then a 6-digit code field that submits on the sixth digit. "Send it again" appears after 30 s.
- Out: new user → O2; returning user → Map.
- States: wrong code "That code didn't match. Check the email and try again."; offline "You're offline. Connect to sign in."

**O2 You.** Purpose: handle, name, age gate.
- Fields: "Handle" (live availability check after 400 ms idle: "Taken" in `brake` or a `go` checkmark), "Name", "Birth year" (wheel picker). Under 17: "Waypoints is for drivers 17 and up." and the button stays disabled.
- `PrimaryButton` "Continue". Out → O3.

**O3 Your car.** Purpose: put a car on the map marker from minute one.
- Title "What do you drive?" The vehicle picker (G4) is embedded directly, not behind a button.
- `QuietButton` "Skip for now" in the navigation bar. Skipping gives the `coupe` silhouette in `dust`.
- Out → O4.

**O4 Location.** Purpose: explain sharing before the system prompt, and set the Nearby choice.
- Top half: a static map of the user's rough region (from locale) with three sample markers showing Precise, Approximate, and nothing, each labelled.
- Text: title "Who sees you", body "Friends see where you are. Everyone else sees nothing unless you say so. You can go ghost any time."
- One choice, two rows with radio marks: "Hide me from drivers nearby" (preselected), "Show drivers nearby roughly where I am (within half a mile)".
- `PrimaryButton` "Turn on location" → system When In Use prompt. `QuietButton` "Not now".
- Out → Map. If denied, the Map shows its no-permission state (M1).

Notifications permission is not asked here. It is asked the first time it has a reason: after the first RSVP ("Remind you before it starts?"), the first friend request sent, or turning on meets-nearby alerts.

### 10.3 Map tab

**M1 Map.** Purpose: the live picture.
- Layout: full-bleed `MKMapView` (dark, muted emphasis, points of interest limited to fuel, parking, EV charging, car wash, and automotive services). Floating over it:
  - Top left: `Avatar` 40 with a status ring: `go` when sharing, dashed `dust` when ghost. Tap → S2 Privacy. Long-press → ghost quick menu ("Go ghost for 1 hour", "Until tomorrow", "Until I turn it off", or "Stop ghost mode").
  - Top centre: search bar (`.regularMaterial`, r12, placeholder "Where to?"). Tap → M2.
  - Right edge, stacked 8 apart: `IconButton` layers (`square.3.layers.3d`) → M8; `IconButton` recenter (`location`; becomes `location.fill` when following, `location.north.line.fill` when heading-up; tap cycles).
  - Bottom right, above the sheet: `IconButton` add (`plus`), 52 pt, the only `sodium` fill. Opens a menu at the map centre: entries supplied by `MapAction` providers in order, e.g. "Report a hazard", "Start a meet", "Start a convoy", "Spot a car". Long-press on the map opens the same menu at that point.
  - Bottom: the map sheet, three detents: 96 pt (handle plus one summary line: "3 friends out · 2 meets tonight"), `medium`, `large`. Content: sections supplied by `MapSheetSection` providers in order: Friends (rows: avatar, name, `CarBadge`, "2.1 mi · moving" in `readoutS`), Meets, Convoy if active, Reports nearby. Background interaction stays enabled through `medium`.
- Selecting a marker or row: camera centres with `camera`, the sheet swaps to that provider's detail view at `medium` with a back chevron (M7, E2, M6…).
- Low zoom: individual markers are replaced by cell counts (a `tarmac` circle with a number at the cell centre). Line under the search bar: "Zoom in to see drivers."
- States:
  - No location permission: map still works. Sheet summary reads "Location is off. You're not on the map." with `QuietButton` "Turn on" (opens Settings app if previously denied).
  - Nobody around: sheet shows "No friends on the map yet." + "Invite a friend" (share sheet with a profile link), then Meets and Reports sections as normal.
  - Connecting: markers render from the last snapshot at 50% opacity until the first batch arrives. `Banner` "Reconnecting" only after 3 s.
  - Offline: `Banner`; map tiles from cache; markers removed after 30 min staleness as usual.

**M2 Search.** Purpose: pick a destination.
- Full-screen cover from the search bar with a zoom from it. Keyboard up immediately.
- Sections before typing: "Recent" (last 5), "Meets tonight" (up to 3), "Saved roads" (up to 3).
- While typing: `MKLocalSearchCompleter` results as rows (name, address line, distance in `readoutS`). People and meets matching the text appear in their own sections below places.
- Tap a place → M3. Tap a person → their peek on the map. "Cancel" dismisses.
- Empty: "Nothing found for '<text>'." Offline: recents only, "Search needs a connection."

**M3 Route preview.** Purpose: choose a route knowing what it does to your car.
- Map shows up to three routes: selected in `sodium` 6 pt, others `dust` 4 pt. Hazards along each route drawn as report glyphs.
- Sheet (`medium`): destination name in `title`; then one row per route: time in `readoutL`, distance and road name in `sub`, and a clearance line when the active car's clearance is not stock: "2 speed bumps, 1 steep entrance" in `sodium`, or "Clear for a lowered car" in `go`. The row with the fewest clearance hazards among routes within 20% of the fastest time is preselected and labelled "Best for your car".
- `PrimaryButton` "Go". `QuietButton` "Share with convoy" when a convoy is active.
- Car switcher: tapping the `CarBadge` at the top of the sheet cycles garage cars (affects the clearance scoring).
- Error: "Couldn't find a route there." + "Try again".

**M4 Navigation.** Purpose: guidance you can read in a glance.
- Top banner (`tarmac`, r20, full width minus margins): maneuver arrow (custom, 44 pt), distance to it in `readoutL`, road name in `bodyStrong`. A smaller second line shows the following maneuver when it is within 300 m of the next.
- Map: heading-up, pitched, following.
- Bottom bar (`tarmac`): arrival time and minutes remaining in `readoutM`, distance; your speed in `readoutXL` inside a capsule at bottom left of the map; `IconButton` mute; `DestructiveButton`-styled "End" (no confirmation; ending is harmless).
- Voice: `AVSpeechSynthesizer`, ducking other audio. Announces at 800 m, 200 m, and at the maneuver. Mute persists.
- Hazard ahead (a clearance report within 250 m on the route, for a non-stock car): a `sodium` strip under the banner "Speed bump in 250 ft", `warn` haptic, one spoken line.
- Off route: silently recalculates; "Rerouting" replaces the road name until done.
- Interaction while moving is limited to mute, End, and the "Still there?" prompt (M6). The add button is hidden above 8 km/h unless a passenger confirms ("I'm a passenger").
- Arrival: banner becomes "You've arrived" with the place name; navigation ends itself after 10 s.
- Lock screen: a Live Activity is not in scope (section 15).
- Offline: guidance continues on the loaded route; rerouting shows "Offline. Follow the route line."

**M5 Report.** Purpose: post a hazard in two taps.
- Sheet, 320 pt. Title "What's here?" A grid of the eight kinds as glyph badge plus name (this is the one grid: it is a palette of equal choices). Tap one → it posts immediately at the chosen point and the sheet closes with `Toast` "Speed bump reported" + "Undo" (5 s) and `done`.
- Optional: before tapping a kind, "Add a note" expands a `Field` (120 characters).
- Rate limit reached: "That's a lot of reports. Try again in a few minutes."

**M6 Report detail.** Sheet content at 220 pt: glyph, kind name in `title`, "Reported 12 min ago · confirmed by 4" in `foot`, note if any. Two buttons side by side: `SecondaryButton` "Still there", `SecondaryButton` "Gone". After voting: both replaced by "Thanks. Counted." While navigating past a temporary report, a compact prompt asks the same question for 8 s, then dismisses itself.

**M7 Driver peek.** Sheet content at 260 pt.
- Friend: `Avatar` 64, name in `title`, handle, `CarBadge`; a line "2.1 mi north east · updated now" (`readoutS`); approximate friends read "Near Cherry Hill · approximate". Buttons: `PrimaryButton` "Directions", `SecondaryButton` "Message", overflow (View profile, Invite to convoy, Remove friend, Block, Report).
- Nearby stranger: silhouette, "A driver nearby", "Approximate location". No name, no car, no profile. One `QuietButton`: "Why can't I see more?" → a two-sentence explanation of nearby privacy with a link to S2.

**M8 Layers.** Sheet, `medium`. Toggles as `Row`s with switches: "Friends", "Drivers nearby", "Meets", "Reports", "Rated roads", "Traffic". Below, `SectionLabel` "YOUR MARKER" and a row "Icon and trail" showing the current `VehicleMarker` → M10.

**M9 Convoy.** Purpose: drive together and stay together.
- Start (from the add menu): sheet with `Field` "Name" (prefilled "<Name>'s convoy"), optional destination row (opens M2 in pick mode), `PrimaryButton` "Start convoy". Result: a 6-character code in `readoutL` with "Share invite" (share sheet with a deep link) and "Invite friends" (multi-select friends list; sends a push).
- Join: deep link or "Join with code" in the same sheet. Before joining: "Everyone in the convoy sees your exact location until you leave." `PrimaryButton` "Join convoy".
- Active: a strip sits above the map sheet at all detents: convoy name, member count, `QuietButton` "Leave". The sheet's Convoy section lists members in road order with gap to the leader as time ("+40 s"), never speed. The shared route draws in `sodium`; members use their precise markers with a `sodium` tick on the leader.
- Regroup: if the last member is more than 3 minutes behind the leader for 60 s, the leader sees a prompt in the strip: "The group has split. Set a regroup point?" Accepting drops a pin at the next safe-looking stop ahead (the nearest fuel or parking point of interest on the route within 3 km, else the leader's current position) and every member gets a banner "Regroup at <place>" with "Directions".
- Voice: every convoy has its own room (CNV-11). A `QuietButton` "Talk" in the strip opens T3 for the convoy room (route `convoyVoice`); you join muted. The room is left when you leave the convoy or it ends.
- End: leader taps "End convoy" (confirmation: "End the convoy for all 6 drivers?"). Others see "Convoy ended."
- Offline member: their marker goes stale by the normal rules; row reads "Lost signal".

**M10 Marker picker.** Purpose: choose how you look on the map.
- Top: a live `VehicleMarker` preview at 2× on a strip of dark map, driving slowly in a loop (static under Reduce Motion).
- `SegmentedSwitch`: "Icon", "Trail".
- A grid of silhouettes (the second and last legitimate grid: a palette). Unlocked ones in your paint color; locked ones in `curb` with a small lock. Tap unlocked → applies immediately, `tick`. Tap locked → a line appears under the preview stating the requirement and your progress: "Rally: get 10 reports confirmed. You're at 6."
- No purchase path. No "coming soon".

**M11 Road detail** (proposal, wave 5). Sheet at `medium`: road name in `title`, length in `readoutM`, three rating bars (Surface, Scenery, Traffic) with averages and count, `PrimaryButton` "Drive it" (routes to the start, then along the path), `SecondaryButton` "Rate" (three 1–5 steppers, "Save"). Creating one: Garage → Drives lists recent recorded drives; open one, drag two handles along the trace to select a stretch, name it, rate it, "Save road". Drive recording is opt-in ("Record my drives on this phone") and traces never leave the device until a stretch is saved.

**M12 Spot** (proposal, wave 5). Camera opens directly. After capture: plates are detected and blurred on-device (Vision text detection, blur any region matching a plate aspect ratio; the user can add or remove blur boxes by tapping). Then the vehicle picker in model-only mode ("What is it?"). `PrimaryButton` "Add to collection". Result: the photo flies into a collection counter with `win`: "Porsche 911 · 3rd spotted". The collection lives in Garage (G1, "Spotted" section): makes as rows with counts, drilling into models with your photos.

### 10.4 Meets

**E1 Start a meet.** Purpose: a meet on the map in under 20 seconds.
- Sheet, `large`. A small map at top with a draggable pin (prefilled from where the add menu was opened); the resolved place name beneath, editable.
- Fields: "What is it?" (`Field`, 50 characters, placeholder "Wawa and chill"); kind as five `Chip`s (Meet, Cruise, Hangout, Track day, Show); "When" with three quick choices ("Now", "Tonight 8 PM", "Pick a time") and an optional end time defaulting to 2 hours after; "Who can see it" (`SegmentedSwitch`: Everyone, Friends, a team if the user has `host_meets` in one).
- "Details" collapses to one line until tapped.
- `PrimaryButton` "Start meet". On success the sheet closes, the pin drops with `sheet`, `done`, and E2 opens.
- Daily limit hit: "You've started 3 meets today. That's the limit."

**E2 Meet.** Sheet content, `medium` and `large`.
- Header: kind glyph, title in `title`, "Tonight 8:00 PM · 4.2 mi" in `readoutM`, place name, host row (avatar, name, tap → profile).
- RSVP: `SegmentedSwitch` "Going", "Maybe", "Can't". Choosing Going asks once which car you are bringing (garage rows) and whether to be reminded.
- "Who's going" — a horizontal strip of `CarBadge`s (cars, not faces: this is what people want to know) with a count; tap → full list.
- Venue notes (proposal): three facts as text rows when present: "Entrance: steep", "Lot: large", "Lit: yes", and `QuietButton` "Add what you know".
- Details text.
- `PrimaryButton` "Directions" → M3. Overflow: Share, Add to Calendar, Report; for the host: Edit, Cancel meet (confirmation "Cancel this meet? 12 people who RSVP'd will be told.").
- Live state: within the time window the header gains a `go` "Happening now"; people within 200 m with a Going RSVP count as checked in.
- Cancelled: header reads "Cancelled" in `brake`; RSVP control removed.

Meets appear in the map sheet's Meets section as rows (glyph, title, time in `readoutS`, distance, going count), sorted by start time; and in M2. There is no separate meets list screen.

### 10.5 Feed tab

**F1 Feed.** Purpose: watch builds.
- Full-screen vertical pager of videos, edge to edge under the status bar; the tab bar stays (opaque).
- Top: `SegmentedSwitch` centred: "Following", "For you", "Showdown". "For you" is recency plus likes within the user's region, then everywhere; no opaque algorithm is claimed.
- Over each video, bottom scrim: author row (`Avatar` 40, handle, "Follow" `QuietButton` if not following), caption (2 lines, tap to expand), `CarBadge` if a car is tagged (tap → G3).
- Right rail, bottom-aligned, three controls only: like (count in `readoutS`), comment (count), share. Double-tap likes with a heart that scales in at the touch point and fades (0.6 s).
- Tap pauses. Long-press → overflow sheet (Not interested, Report, Block).
- Playback: autoplay muted until the user unmutes once per session; loops; the next video's first 2 s are preloaded.
- Top right: `IconButton` `plus` → F3.
- Empty (Following): "Nobody you follow has posted yet." + "See For you". Empty (For you, new region): "No videos near you yet. Post the first one." + "Post a video".
- Error: the frame shows the poster image with "Couldn't play this." + "Try again"; swiping still works.
- Offline: poster images of cached items; "Offline" `Banner`.

**F2 Comments.** Sheet, `medium`/`large`. Rows: avatar, handle, text, relative time. Composer pinned at the bottom: `Field` "Add a comment", send `IconButton` enabled when non-empty. Empty: "No comments yet." Swipe a row you own → Delete.

**F3 Post a video.** Purpose: post in three steps.
- Step 1: system photo picker filtered to videos, or record. Videos over 30 s open a trim strip.
- Step 2: caption `Field` (150), "Tag a car" row (your garage), cover frame scrubber.
- `PrimaryButton` "Post". Export to HEVC 720p (cap 12 MB), upload with a progress bar under the navigation bar; the user can leave the screen and the upload continues in a `Task` owned by `FeedFeature`'s upload actor. `Toast` "Posted" or "Couldn't post. Saved as a draft." (draft kept on device).

**F4 Showdown.** Purpose: pick the better build, fast.
- Two cars stacked, each half the screen: the car's lead photo full-bleed, and at its inner edge `CarBadge`, owner handle, and two readouts: "est. hp" and build-entry count.
- Tap a half, or drag it toward the centre, to pick it. Past the threshold: `set`; on release: `thud`, the winner expands to full screen for 0.5 s (`win`) showing its new rank movement ("▲ 3 in Street" in `readoutM`), then the next pair slides up.
- Top: class `Chip`s (Street, Built, Show, Classic) and `IconButton` `list.number` → F5.
- "Skip" `QuietButton` at the bottom centre. Tap a photo's `CarBadge` → G3 (returns to the same pair).
- Pairing: two cars of the same class within 150 rating points, never your own, never a pair you have judged.
- Enter your car: from G3. Requirements stated there: at least one photo.
- Empty: "You've judged every pair in Street. Try another class."

**F5 Rankings.** `SegmentedSwitch` "This week", "All time"; class `Chip`s. Rows: rank in `readoutM`, lead photo thumbnail (r6), `CarBadge`, owner, rating in `readoutS`. Your own cars are pinned in a "Yours" section at the top with their ranks. Tap → G3.

### 10.6 Market tab

**K1 Browse.** Purpose: find a part or a car.
- Top: search `Field` "Search parts and cars". Under it a single filter line: `SegmentedSwitch` "Parts", "Cars"; then a "Fits" control showing the active garage car ("Fits: 2019 Mustang GT", tap to change car or clear) for Parts; and `IconButton` filter → sheet with price range, condition, distance.
- Results: Parts as a two-column grid of cards (photo r12, title 2 lines, price in `readoutM`, region in `foot`); Cars as full-width rows with a 16:9 photo, title, price, mileage if given.
- Top right: `IconButton` `plus` → K3. Top left: `IconButton` `tray` → K4.
- Empty with filter: "Nothing listed for a 2019 Mustang GT yet." + `QuietButton` "Search all cars". Empty overall: "Nothing for sale near you yet." + "List something".

**K2 Listing.** Photo pager (zoom transition from the card), title in `title`, price in `readoutL`, condition and region, "Fits" line, description, seller row (avatar, handle, member since, tap → profile). Bottom bar: `PrimaryButton` "Message seller" → T7 thread for this listing, with the composer prefilled "Is this still available?"; `IconButton` save. Own listing: bottom bar is "Mark as sold" and "Edit". A safety line in `foot` `dust` above the bar: "Meet in a public place. Waypoints doesn't handle payment." Sold: price struck through, "Sold" label, message button removed.

**K3 List something.** Steps on one scrolling screen: photos (up to 8, first is cover, drag to reorder); "What is it?" `SegmentedSwitch` Part / Car; title; price (numeric keypad, `readoutL` as typed); condition `Chip`s; for a part, "Fits" (vehicle picker in range mode: make, model, year from–to); for a car, "Choose from your garage" (prefills everything from the car) or the picker; description; region (prefilled from profile). `PrimaryButton` "List it". Missing fields scroll into view with their error text.

**K4 Yours.** `SegmentedSwitch` "Selling", "Saved". Rows with thumbnail, title, price, status. Swipe on a selling row: "Sold", "Remove". Empty: "You haven't listed anything." + "List something" / "Nothing saved yet."

### 10.7 Teams tab

**T1 Teams.** Purpose: get to a conversation.
- Left rail, 64 pt wide: at top a `bubble.left.and.bubble.right` button for direct messages (with unread count), a `seam`, then team icons (r12 squares, 44 pt; the selected one has a 2 pt `sodium` ring), then `plus` → T4.
- Right pane: for a team — header with team name in `title`, tag in `readoutS`, member count; tap header → T5. Then `SectionLabel` "TEXT" with channel rows ("# general", bold with a count when unread), `SectionLabel` "VOICE" with voice channel rows showing avatars of who is in them; then "Upcoming" with the team's next meet if any.
- For direct messages — thread rows: avatar, name, last message line, time; listing threads show the listing thumbnail in place of the avatar corner.
- Empty (no teams): right pane reads "Teams are where your people talk. Join one or start your own." + `PrimaryButton` "Find a team" and `SecondaryButton` "Start a team" (both → T4).
- Tap channel → T2; voice channel → T3; thread → T7.

**T2 Channel.** Purpose: chat.
- Messages bottom-anchored. Consecutive messages from one author within 5 minutes group under one header (avatar 40, name colored by role, time in `foot`). Day dividers as centred `label` text.
- Attachments: one image per message, r12, tap to zoom.
- Composer: `Field` "Message #general", `IconButton` photo, send. Send fires `tap`; the message appears immediately at 60% opacity until confirmed; failure shows "Not sent. Tap to retry." under it.
- Long-press a message: Copy, Reply (quotes the first line), Delete (own, or with permission), Report.
- Mentions: typing "@" opens a member list above the composer.
- Top right: `IconButton` `person.2` → T6.
- Loading older messages: pull at top; a `Skeleton` of three rows.
- Empty: "This is the start of #general."
- Offline: composer disabled with placeholder "Offline"; cached messages shown.
- Text is passed through `SafetyKit`'s filter before send; a blocked message shows "That message can't be sent."

**T3 Voice.** Purpose: talk while driving, hands off.
- A sheet at 320 pt over wherever the user is (it persists as a 44 pt strip above the tab bar when collapsed: channel name, speaking indicator, mute, leave).
- Content: channel name, grid of participant avatars 64 with name; a speaking participant has a `xenon` ring. Three controls in a row: mute (`mic` / `mic.slash`), speaker route (system route picker), `DestructiveButton` "Leave".
- Join is muted by default: "You're muted. Tap to talk."
- Mic permission is asked on first unmute. Denied: "Microphone is off for Waypoints." + "Open Settings".
- Limit reached (free LiveKit minutes exhausted): "Voice is unavailable right now. Try again later."
- Connecting: avatars appear at 50% with "Connecting". Lost: "Reconnecting" for up to 15 s, then leaves with `Toast` "Voice disconnected."

**T4 Find or start a team.** `SegmentedSwitch` "Find", "Start".
- Find: `Field` "Search teams or paste an invite"; public teams as rows (icon, name, tag, member count, about line) sorted by members in your region; `SecondaryButton` "Join" per row. An invite code typed or pasted resolves to its team with "Join".
- Start: icon picker (photo, or a tag-initial tile), "Name", "Tag" (2–5 letters, shown uppercase, availability checked), "About", switch "Anyone can find and join". `PrimaryButton` "Start team" → the new team's `general`.

**T5 Team.** Icon 96, name, tag, about, member count. Rows: "Invite people" (share link with code), "Members" → T6, "Meets" (team meets list). With permission: "Channels" (add, rename, reorder, delete), "Roles" (list; a role editor with name, color from 8 swatches, and permission switches each with a one-line description), "Edit team". `DestructiveButton` "Leave team" (owner sees "Delete team" with typed-name confirmation).

**T6 Members.** Rows grouped by role in rank order: avatar, name, `CarBadge`. Tap → profile. With permission, swipe: "Change role", "Remove".

**T7 Direct thread.** Same as T2 without roles or mentions. A listing thread pins a compact listing row (thumbnail, title, price, status) at the top; tap → K2. First message to someone who is not a friend lands in their "Requests" section of the direct messages list with Accept / Block.

### 10.8 Garage tab

**G1 Garage.** Purpose: your profile and your cars.
- Navigation bar: handle in `title` at left; `IconButton` `person.badge.plus` (friend requests, with count) → G11; `IconButton` `gearshape` → S1.
- Header: `Avatar` 96, name, bio, home region; three counts in `readoutM` with `foot` labels: friends, followers, spotted. `SecondaryButton` "Edit profile" → G10.
- `SectionLabel` "CARS". Each car is a full-width card: lead photo 16:9 (r20), a 3 pt paint-color bar along its bottom edge, then nickname or "2019 Mustang GT" in `title`, trim in `sub`, and est. power in `readoutM`. Tap → G3. After the last card, a `SecondaryButton` "Add a car" → G4.
- `SectionLabel` "SPOTTED" (wave 5): top makes with counts; "See all".
- `SectionLabel` "POSTS": a three-column grid of video posters (the profile grid is the Instagram pattern, kept because it is the fastest way to scan someone's posts).
- Empty (no cars): the cars section is one block: "Your garage is empty." + `PrimaryButton` "Add your car".

**G2 Someone's profile.** Same layout as G1 without edit controls. Under the header: `PrimaryButton` "Add friend" (→ "Requested" → "Friends"), `SecondaryButton` "Follow", `IconButton` message. Overflow: Share profile, Block, Report. A blocked or blocking user: "This profile isn't available."

**G3 Car.** Purpose: the build.
- Photo pager at top (4:3), page dots; zoom transition from the card.
- Title block: nickname in `display` if set, "2019 Ford Mustang GT" in `title`, trim and color name in `sub`.
- Readout row (four across, each `Readout` with a `label`): "EST. HP", "EST. TQ", "0–60", "¼ MILE". Ranges shown as the thin bar. A `foot` line: "Estimates from stock specs and listed mods." Tap the row → G6.
- Actions (own car), as rows: "Mod simulator" → G6, "Run the strip" → G7, "Enter Showdown" (or "In Showdown · #14 Street"), "Edit car" → G4 in edit mode.
- `SectionLabel` "TIMELINE": entries newest first, each a row with date in `readoutS`, title in `bodyStrong`, body, optional photo. Own car: "Add an entry" → G5.
- `SectionLabel` "SPECS": a plain two-column table (engine, drivetrain, transmission, weight, clearance), each value marked "stock" or "edited".
- Other people's cars: actions are replaced by owner row and "Message about this car".
- Empty timeline (own): "No entries yet. Log the first thing you did to it." + "Add an entry".

**G4 Vehicle picker.** Section 11.1 specifies it fully.

**G5 Timeline entry.** Sheet, `large`: date (defaults to today), "What did you do?" (60), "Details" (500), one photo, and "Link a mod" (opens the mod list filtered to this car; linking adds the mod to the car's mod list so the simulator reflects it). `PrimaryButton` "Add to timeline".

**G6 Mod simulator.** Purpose: see and hear what a mod does.
- Top third: a dyno chart: stock power and torque curves in `dust`, modified curves in `sodium` (power solid, torque dashed), rpm on x. Drag across the chart to scrub rpm: a vertical line with readouts, `tick` at each 500 rpm, and the engine sound follows the scrubbed rpm while the finger is down.
- Under it, four `Readout`s as in G3, each showing the change from stock ("+84") in `go`, with ranges.
- A `foot` line that is always visible: "Estimates. Real results depend on the tune, the dyno, and the day."
- Sound control: a large hold-to-rev pad ("Hold to rev"): pressing sweeps rpm up through the simulated first gear, releasing lets it fall with overrun crackle if a tune allows it. A small switch "Sound" mutes.
- Mod list, grouped with `SectionLabel`s: INTAKE, EXHAUST, TUNE, FORCED INDUCTION, FUEL, WEIGHT. Each mod is a `Row` with a switch, its name, and its own range ("+10 to +18 hp"). A mod that needs another shows "Needs a tune" under its name and turning it on offers "Add Stage 1 tune too". A mod with a manufacturer claim shows a small "claimed" tag; a heuristic shows "typical".
- Top right: "Save to car" (writes the mod list; also offers "Add to timeline").
- Unsupported car (no specs): "We don't have specs for this car. Enter power and weight to simulate it." + "Enter specs" (four fields).
- No network needed; everything is local.

**G7 Strip lobby.** Purpose: set up a virtual run.
- Header line, always: "Virtual drag strip. A game, not a challenge. Keep it off the street."
- Your car card with est. ¼ mile. Opponent choice as rows: "Your best run" (ghost), "A friend's run" (friends with results), "House car" (three fixed difficulty cars defined by plain specs).
- `PrimaryButton` "Stage" → G8. `QuietButton` "Past runs" (list of time slips).

**G8 Run.** Landscape-locked SpriteKit scene.
- Side view: two lanes, a Christmas tree at centre, a tachometer arc with shift light, gear number, and nothing else.
- Controls: right thumb holds throttle; left thumb taps to shift. Before the tree: hold throttle to set launch rpm. Leaving before green is a red light.
- The physics is `PerformanceModel`'s longitudinal simulation at 240 Hz with the player's inputs. Engine sound from `EngineAudio`.
- Pause: two-finger tap → Resume, Restart, Quit.

**G9 Time slip.** Styled as a printed slip: monospaced rows in `readoutM` on `chalk` with `asphalt` text (the single light surface in the app, because it is a piece of paper): R/T, 60 ft, ⅛ ET and mph, ¼ ET and mph, for both lanes; winner marked. Below, on `asphalt`: "Run again", "Change opponent", share (renders the slip as an image with "Virtual run · Waypoints" printed on it).

**G10 Edit profile.** Avatar (photo picker with circular crop), name, handle, bio, home region. "Save" in the navigation bar, enabled when changed.

**G11 Friends.** `SegmentedSwitch` "Friends", "Requests". Search `Field` at top finds people by handle. Friends rows: avatar, name, `CarBadge`; swipe: Remove. Requests rows: Accept (`SecondaryButton`), Decline (`QuietButton`). "Invite a friend" row at the top (share link). Empty requests: "No requests."

### 10.9 Settings

**S1 Settings.** Rows: "Privacy and location" → S2, "Notifications" → S3, "Blocked people" → S4, "Account" → S5, "About" → S6. Debug builds add "Design gallery".

**S2 Privacy and location.** Purpose: control who sees you, in one screen.
- Top: a live preview map strip showing your marker three ways side by side, labelled "Friends see", "Teams see", "Drivers nearby see", each rendering exactly what that audience gets right now (precise marker, approximate ring, or "Nothing").
- "Ghost mode" row with a switch; turning on asks for duration. When on, a line: "Ghost until 6:00 AM. Nobody sees you."
- `SectionLabel` "WHO SEES YOU": three rows, each opening a three-option (or two-option for nearby) choice with one-line descriptions: Precise "Your exact position, live."; Approximate "A half-mile area, updated every 15 seconds."; Hidden "Nothing. You look offline."
- `SectionLabel` "HOME ZONES": rows for each zone (name, "300 m") and "Add a zone" (map with a draggable circle; name field). Footer: "Inside a zone, nobody gets your exact position. Zones are stored on this phone."
- `SectionLabel` "BACKGROUND": switch "Keep sharing when the app is closed" (triggers the Always prompt, preceded by a sentence explaining battery use and that it stops after 5 minutes parked).
- Switch "Record my drives on this phone" (wave 5).
- Changes save immediately; failure reverts the control and shows "Couldn't save. Try again."

**S3 Notifications.** Switches: "Meets near me" (with a radius stepper 5–50 km), "Friend requests", "Messages", "Mentions", "Convoy invites", "Meet reminders". If system permission is off: a block at the top "Notifications are off for Waypoints." + "Open Settings".

**S4 Blocked people.** Rows with "Unblock". Empty: "You haven't blocked anyone."

**S5 Account.** Email (read-only), "Sign out", `DestructiveButton` "Delete account" → explains what is deleted (profile, cars, posts, messages you sent, listings) and requires typing the handle; deletion is immediate and signs out.

**S6 About.** Version, Terms, Privacy Policy, "Contact" (mailto to the address in section 14), open-source licences (B612 OFL text, package licences).

### 10.10 Shared

**X1 Report or block.** Sheet, `medium`. Title "Report <thing>". Reasons as rows with radio marks: Spam, Harassment, Nudity, Dangerous driving, Scam, Something else. Optional note. Switch "Also block <handle>" (on by default for harassment). `PrimaryButton` "Send report". Result: "Reported. We review reports within 24 hours." The reported item disappears for the reporter immediately.

**X2 Terms gate.** Shown once after O2 and whenever terms change: the rules in six plain lines (no harassment, no nudity, no street racing content, no scams, report what you see, we remove violators), links to full Terms, `PrimaryButton` "Agree".

**X3 Deep links.** `waypoints://` and universal links for profile, car, meet, team invite, convoy invite, listing, post. Signed-out users land on O1 and continue to the target after sign-in.

Contract change: the universal-link form is `https://<LINK_HOST>/<path>` with the same paths as `waypoints://` (`profile/<id>`, `car/<id>`, `meet/<id>`, `team/<id>`, `listing/<id>`, `post/<id>`, `invite/team/<code>`, `invite/convoy/<code>`). `LINK_HOST` is one value in `Config.xcconfig`, read through Info.plist `WPLinkHost` into `AppConfig.linkHost` and `DeepLink.linkHost`, and used by the associated-domains entitlement (`applinks:$(LINK_HOST)`). `Route.shareURL` (Core, so features can use it) and `DeepLink.url(for:)` return the https form when a host is set, else `waypoints://`; every share sheet builds its link through `Route.shareURL`. The host serves `site/` (LINK-4); without the app, `site/404.html` says what the link is and where to get Waypoints.

---

## 11. Feature engineering notes

### 11.1 Vehicle catalog and picker

**Sources** (all free, all US federal data):

| Source | Gives | Limits |
|---|---|---|
| NHTSA vPIC API (`vpic.nhtsa.dot.gov/api`) | Makes; models per make and year (`GetModelsForMakeYear`). VIN decode. | No trims, no colors, no specs in the picker endpoints. Rate limiting is unspecified: keep to 2 requests per second and cache every response on disk. |
| EPA fueleconomy.gov `vehicles.csv` | 1984 onward: engine displacement, cylinders, drive, transmission, turbo and supercharger flags, per model variant. | No power, no weight, no clean trim field. |
| EPA annual test car list files *(verify fields before use)* | Rated horsepower, test weight (roughly curb + 300 lb), axle ratio, gears. | No torque. Weight is binned. |
| `tools/catalog/overrides.csv` (ours, hand-kept) | Trim names, torque, redline, gear ratios, curb weight for enthusiast models. Starts with about 150 model-generations (Mustang, Camaro, Corvette, Challenger, Charger, WRX, BRZ/86, Civic Si/Type R, GTI/R, Miata, 350Z/370Z/Z, Supra, M3/M4, 335i/340i, S4, Golf, Focus ST/RS, Silverado, F-150, Ram, Tacoma, and so on). | Manual work; grows over time. |

Paint: there is no free factory color database. The picker offers 16 color families (each with a representative hex), a custom color wheel, and an optional free-text paint name ("Grabber Blue"). Each make's ten most-entered paint names are suggested from other users' entries once there are enough.

**Pipeline** (`tools/catalog`, Go): fetch and cache vPIC for a curated list of about 90 passenger makes × model years 1981–2027; load EPA CSVs; normalize names; join; apply overrides; write `catalog.sqlite` with tables `make(id, name)`, `model(id, make_id, name, year_from, year_to)`, `variant(id, model_id, year, trim, engine, displacement_l, cylinders, aspiration, drive, transmission, hp, torque_lbft, weight_lb, redline, gears_json, spec_source)` and an FTS5 table over "year make model trim". Expected: about 25,000 model-years, 60–90,000 variants, 6–15 MB, 2–4 MB compressed *(estimate)*.

**Caching**: a snapshot ships inside the app bundle (LZFSE-compressed, expanded to Application Support on first run). On launch, at most once a day, the app reads `catalog/manifest.json` from Supabase Storage (`{version, url, sha256, bytes}`); a newer version downloads in the background and swaps in atomically on next launch. The picker never waits on the network.

Every spec is user-overridable (`cars.spec_overrides`), and the car row stores make, model, and trim as text, so a catalog gap never blocks adding a car.

**The picker (G4).** The catalog is large; the screen must feel like there are only ever a few things to choose from.

- One screen, one question at a time. A breadcrumb line under the title records answers so far as tappable tokens: "Ford · Mustang · 2019". Tapping a token goes back to that step with later answers cleared.
- A search field stays at the top through every step: "Search, like '2019 mustang gt'". It parses tokens in any order (a 4-digit year, then make and model by prefix and FTS) and shows up to 8 direct matches as rows ("2019 Ford Mustang GT · 5.0 L V8 · manual"). Choosing one jumps straight to color. This is the fast path: about ten keystrokes and two taps.
- Step 1, Make: "Popular" (12 makes as text rows, ordered by how many cars exist in the app, seeded with a fixed list), then A–Z with a section index. Text only, no logos.
- Step 2, Model: models of that make, current ones first, then "Older models". Each row shows its year span in `readoutS`.
- Step 3, Year: a horizontal strip of years the model existed, newest at the leading edge, grouped by generation with a thin gap between generations; `tick` on each. Not a wheel of every year since 1981.
- Step 4, Trim: rows for that year's variants: trim name, then engine, drive, and transmission in `sub`. If there is exactly one, the step is skipped. Last row: "Mine isn't listed" → a short form (trim name, engine, drive).
- Step 5, Color: 16 family swatches in two rows; picking one tints a large silhouette of the chosen marker icon above them. "Exact color" opens the wheel. "Paint name" is an optional `Field` below.
- `PrimaryButton` "Add to garage" appears only on step 5. Steps advance on selection with `standard`; there is no "Next" button.
- "Use VIN" in the navigation bar: camera with `DataScannerViewController` reading a barcode or text, or type 17 characters; decoded through vPIC `DecodeVinValues`, landing on step 4 or 5 with what was resolved. Offline: "VIN lookup needs a connection."
- Modes used elsewhere: model-only (Spots), range (Market "Fits": make, model, year from–to).

### 11.2 Performance model

Module `PerformanceModel`. Pure, deterministic, synchronous, `Sendable`. No UI, no I/O.

```swift
public struct VehicleSpec: Sendable { hpCrank, torqueLbFt, weightLb, drivetrain (.fwd/.rwd/.awd), aspiration (.na/.turbo/.supercharged),
                                      redline, gearRatios: [Double], finalDrive, tireRadiusM, cdA, cylinders, layout (.inline/.v/.flat/.rotary), crankPlane }
public struct Estimate: Sendable { hp, torque, zeroToSixty, quarterET, quarterTrap: ClosedRange<Double>; curve: [CurvePoint] }
public func estimate(base: VehicleSpec, mods: [Mod]) -> Estimate
public func simulateRun(spec: VehicleSpec, mods: [Mod], inputs: RunInputs, dt: Double) -> RunResult   // drives the Strip too
```

**Power with mods.** Gains do not add: parts relieve the same restriction, and on turbocharged engines the tune is what turns flow into boost.

`P = P_base × (1 + B) × (1 + T) × (1 + F)`

- `B`, breathing (intake, exhaust, headers, downpipe): saturating. `B = B_max × (1 − Π(1 − b_i / B_max))`, with `B_max` 8% naturally aspirated, 12% turbocharged. A part flagged `requiresTune` contributes a quarter of its gain without a tune.
- `T`, tune and fuel: tune stage and E85 terms, multiplied.
- `F`, forced-induction kit: when a platform-specific kit is selected it replaces `B` and `T` with the kit's own figure for that platform.

Every mod carries a low and a high gain; the model runs both ends and reports the range.

**Mod catalog** (`tools/mods/mods.json`, bundled): `id, category, name, brand?, appliesTo {aspiration[], platformIds[]}, hpGainPct {low, high}, tqGainPct {low, high}, absolute {hp, tq}?, curveShape {low, mid, top}, requires[], requiresTune, conflicts[], weightDeltaLb, sound {…section 11.3}, confidence, sourceURL`.

Confidence is shown to the user: `A` independent dyno ("measured"), `B` manufacturer figure ("claimed"), `C` rule of thumb ("typical").

Generic gains (confidence C; typical dyno ranges):

| Mod | Naturally aspirated | Turbocharged |
|---|---|---|
| Intake | 0–2% | 1–3% |
| Cat-back exhaust | 0–2% | 1–3% |
| Long-tube headers (with tune) | 4–7% | n/a |
| Downpipe (needs tune) | n/a | 3–8% |
| Tune (Stage 1) | 2–5% | 15–30% |
| Stage 2 (bolt-ons and tune, total) | n/a | 25–40% |
| E85 on top of a tune | 3–5% | 10–20% |

Platform kits seeded for the 2024+ Mustang GT (stock 486 hp), confidence B, advertised crank figures on 93 octane: Ford Performance/Whipple 750 hp and 615 lb-ft; Whipple Gen 6 3.0 L Stage 1 810 hp and 640 lb-ft; Whipple Stage 2 up to 875 hp and 660 lb-ft; Roush Phase 2 (TVS R2650) 810 hp and 630 lb-ft. Earlier S550 kit figures must be sourced by the package before being added. Package W4-1 seeds at least 40 generic mods and kits for 6 platforms, each with a source URL.

**Acceleration.** A longitudinal simulation, also used by the Strip:

`F = min(T(rpm) × gear × final × η / r, F_traction) − ½ρ·CdA·v² − C_rr·m·g`, `a = F / (m × k)`

- Torque curve synthesized from peak power, peak torque, and redline (shape by aspiration; a centrifugal supercharger rises with rpm, a positive-displacement one is flat).
- Traction limit by drivetrain with weight transfer: RWD `μ(l_f/L) / (1 − μh/L)`, FWD `μ(l_r/L) / (1 + μh/L)`, AWD `μ`; street tire μ = 0.95.
- Driveline efficiency η: 0.88 manual 2WD, 0.85 automatic 2WD, 0.80 AWD. Inertia factor k from 1.25 in first gear to 1.05 in top. Shift time 0.25 s manual, 0.12 s dual-clutch or modern automatic. One-foot rollout for the quarter mile. `dt` 4 ms for estimates, 1/240 s in the game.
- Missing gear ratios fall back to a typical set for the transmission type and the estimate widens.

**Honesty.**

- Expected error with real gear ratios: trap speed ±3%, quarter-mile time ±5%, 0–60 ±0.4 s; without them, about double. High-power two-wheel-drive cars on street tires are the least accurate (traction dominates).
- As a sanity check the model also computes Hale's formulas (`ET = 5.825 × (W/P)^⅓`, `mph = 234 × (P/W)^⅓`); if the simulation and the formula differ by more than 12% the range is widened to cover both.
- The interface always shows ranges, always says "est.", and G6 carries the fixed disclaimer line.
- Drivetrain-loss percentages are folklore; they are used only to convert a user-entered wheel horsepower to crank, labelled "approximate".
- Acceptance without a test target: `PerformanceModel` includes a `ReferenceCars.swift` table of 12 stock cars with published times, and a debug screen in the gallery listing model output beside published figures. Done means all 12 fall inside the stated error.

### 11.3 Exhaust sound

Module `EngineAudio`. Procedural synthesis, because recordings for a whole catalog do not exist under a licence we can ship.

**Signal path**, per audio frame, driven by rpm and load (0–1):

1. **Firing pulses.** Firing frequency = rpm / 60 × cylinders / 2. One pulse per cylinder event, timed by the engine's real firing intervals: cross-plane V8 has uneven spacing within each bank (90, 180, 270, 180 degrees), which is the burble; flat-plane V8 and inline-4 are even; a boxer with unequal headers gets per-cylinder delay offsets, which is the rumble; inline-6 is even at 120 degrees. Each pulse is a short asymmetric burst whose amplitude and brightness rise with load, with 1–3% timing jitter and amplitude variance so it does not sound like a buzzer.
2. **Pipes.** Each bank feeds a waveguide (delay line with a reflection coefficient and loss filter) sized to a nominal header-and-pipe length; banks merge (or stay separate for true duals).
3. **Muffler.** A low-pass filter plus broadband attenuation, and a resonator notch.
4. **Radiation.** A high-pass at the tailpipe and a light stereo spread between two tips.
5. **Layers.** Intake noise (band-passed noise rising with load); supercharger whine (a tone at rpm / 60 × pulley ratio × lobe count, level with load); turbo whistle (filtered noise following a lagged spool state) and a blow-off burst on lift; overrun crackle (random bursts into the pipe model when throttle closes above 3,500 rpm, only with a tune that enables it).

**What mods change** (plausible mappings, not measurements):

| Mod | Parameter change |
|---|---|
| Cat-back | +3 dB, muffler cutoff up 30% |
| Muffler delete | +8 dB, cutoff up 80% |
| Resonator delete | notch removed: more rasp at 2–4 kHz, a drone peak near 120 Hz at cruise rpm |
| Headers / high-flow cats / downpipe | brighter pulses; stronger pipe reflection |
| Straight pipe | minimal filtering, maximum reflection |
| Tune with burble | crackle enabled |
| Supercharger / turbo | whine or whistle layers on; a turbo also softens pulses (the turbine damps them) |

**Realtime rules.** The render block of `AVAudioSourceNode` runs on the audio thread. In it: no allocation, no locks, no Objective-C or Swift runtime calls, no class references retained or released, no actor hops. The kernel is a `final class` holding preallocated `UnsafeMutablePointer` buffers; parameters cross from the main actor through `Synchronization.Atomic` values (iOS 18) and are smoothed per sample. The render closure is created in a `nonisolated` function so it does not inherit main-actor isolation. This kernel is the only `@unchecked Sendable` type in the app, and the file says why.

**Honesty.** This will sound like a believable engine of the right layout that changes in the right direction when mods change. It will not sound like a recording of a particular car, and sustained high-load notes will read as synthetic. G6 does not claim otherwise; the sound switch is labelled "Synthesized sound". Left out: recorded samples and convolution with measured exhaust impulse responses (no licensable source).

### 11.4 The Strip (virtual racing)

- Quarter-mile drag racing only. Side-view SpriteKit scene; simulation from 11.2 at a fixed 240 Hz step, decoupled from rendering.
- Skill is reaction time, launch rpm, and shift timing. The car's simulated performance comes from its real garage specs and mods, which is the point.
- Opponents: your own best run, a friend's stored run (replayed from its input log through the same simulation), or three house cars. No live multiplayer (section 15).
- Results are stored (`race_results`) and feed two marker unlocks. There is no global leaderboard of times.
- App Review guardrails, all mandatory: the word "virtual" in the lobby, on the slip, and in shared images; nothing on the map refers to racing; no GPS, real speed, or real location is read by this feature; no challenge can be sent that references a place or a time to meet; opponent taunts and wagers do not exist.

### 11.5 Navigation on MapKit

MapKit gives routes (`MKDirections`, with alternates) and step geometry, not a guidance engine. `NavigationFeature` builds:

- **Progress tracking**: snap each location sample to the route polyline; current step is the one containing the snapped point; distance to maneuver along the polyline.
- **Off-route**: more than 40 m from the polyline for 5 s (or 3 consecutive samples heading away) triggers a new `MKDirections` request from the current position. At most one request every 8 s.
- **Voice**: phrases are built from step data by our own templates ("In 800 feet, turn right onto Haddonfield Road"), not read from `MKRoute.Step.instructions`, which is display text. Units follow the locale.
- **Low-car scoring**: for each alternate, call `hazards_along(path, 25)`; count kinds that matter for the active car's clearance (`lowered`: steep entrances, speed bumps; `slammed`: those plus potholes and rough road). Preselect as in M3. The limit, stated in the interface when no clean route exists: "No route avoids these. Apple Maps routing can't be steered around them." We cannot ask MapKit to avoid a point.
- `NavigationFeature` runs as an actor consuming `LocationService.samples()`, publishing `NavigationState` to the main actor.

Left out: lane guidance, speed limits (not exposed by MapKit), CarPlay (needs an entitlement Apple grants on request; listed in section 14 as optional), offline routing.

---

## 12. Work packages

Rules for every package:

- Read sections 1, 4, 9.11, and whatever the package lists under "Read".
- Edit only files under "Owns". Reading anything is fine.
- Build against `Core` protocols and `PreviewEnvironment`; never import another feature.
- Done means: `make build` exits 0 with zero warnings in owned code; the acceptance list is demonstrated (in the simulator for iOS work, by running the binary for Go work); committed to `main` with a message starting with the package id.
- No test targets. Verification is by running.
- If a contract in section 4.3, 5, or 6 is wrong or missing something, do not work around it locally: make the smallest change to the contract, note it in the commit message under "Contract change:", and update this document in the same commit.

`make build` runs: `go build ./... && go vet ./...` in `server/` and `tools/catalog/`; `xcodegen generate` in `ios/`; `xcodebuild -scheme Waypoints -destination 'generic/platform=iOS Simulator' build` with warnings as errors for Swift concurrency diagnostics.

### Wave 0: foundations

**W0-A Scaffold and contracts** (runs first, alone)
- Goal: an app that builds and launches to a signed-out screen, with every module and every contract in place.
- Read: 3, 4, 5, 10.1.
- Owns: `Makefile`, `README.md`, `.gitignore`, `ios/project.yml`, `ios/App/**`, `ios/Packages/WaypointsKit/Package.swift`, `Sources/Core/**`, `Sources/AppShell/**`, and the single stub file `Sources/<Module>/<Module>.swift` for every other module in 4.1.
- Exposes: everything in 4.3; all repository protocols; all domain models mirroring section 5; `PreviewEnvironment`; `FeatureRegistry`; the tab shell and router; `ios/App/CompositionRoot.swift` that builds `AppEnvironment` by calling each infrastructure module's factory (`Backend.makeLive(config:)`, `RealtimeClient.makeLive(config:)`, and so on), each of which returns the preview implementation until its owner replaces it. Configuration (Supabase URL and anon key, gateway URL) is read from `ios/App/Config.xcconfig`, with `Config.example.xcconfig` committed and the real file ignored.
- Acceptance: `make build` passes on a clean clone after `brew install xcodegen`. Swift 6 mode and complete concurrency checking are on for every target. The app launches in the simulator and shows only tabs whose feature is available (none yet: it shows the O1 stub). `AppShell` contains no feature-specific code beyond calling `register`.

**W0-B Wire contract and gateway skeleton** (after W0-A)
- Goal: the protocol compiles in both languages and a gateway process answers health checks.
- Read: 4, 6, 7.2.
- Owns: `proto/**`, `server/go.mod`, `server/cmd/gateway/**`, `server/internal/app/**`, `server/internal/wire/**`, `server/internal/metrics/**`, a stub `register.go` in every other `server/internal/*` package, `Sources/WireProtocol/**`, the `make proto` target's script `tools/proto.sh`.
- Exposes: generated Go and Swift types (committed, so builds do not need `protoc`); `app.App` with config (env vars, listed in `server/README.md`), logger, lifecycle, HTTP mux, and the `Register` registry; `/healthz`; `/metrics`.
- Acceptance: `make proto` regenerates identical output; `go run ./cmd/gateway` serves `/healthz`; graceful shutdown on SIGTERM within 5 s.

**W0-C Database** (after W0-A, parallel with B and D)
- Goal: the complete schema of section 5, applied to a local Supabase.
- Read: 2.5, 5.
- Owns: `supabase/**`.
- Exposes: tables, RLS policies, RPCs, triggers (like counts, default team roles and channels, profile row on sign-up), storage buckets and policies, Realtime publication for `messages`, and `supabase/seed.sql` with 12 plausible users, 20 cars, 6 meets, 30 reports, 3 teams around one metro area.
- Acceptance: `supabase db reset` applies cleanly; a script `supabase/checks.sql` demonstrates, by running as two different users, that each access rule in section 5 holds (it prints one line per rule: rule name and PASS or FAIL).

**W0-D Design system** (after W0-A, parallel with B and C)
- Goal: section 9 as code.
- Read: 9 in full, 10.1.
- Owns: `Sources/DesignSystem/**`, `ios/App/Fonts/**` (B612 Mono and its licence).
- Exposes: tokens, every component in 9.9, `VehicleMarker`, the 16 free silhouettes plus report glyphs and meet pins as vector assets, `Haptic`, `Motion`, `Gallery`.
- Acceptance: the gallery shows every token and component; a contrast audit view lists every text-on-surface pair with its ratio and none fail; markers are legible at 28, 40, and 44 pt over a dark map screenshot in the gallery; Dynamic Type AX5 does not clip any component; no literal colors or sizes outside the token files.

**W0-INT** (alone): build everything together, fix seams, confirm a clean clone builds with the documented steps, update `README.md` with them.

### Wave 1: you, your car, your friends on a live map

**W1-1 Backend**
- Goal: real data.
- Read: 4.3, 5.
- Owns: `Sources/Backend/**`.
- Consumes: `Core` protocols; W0-C schema.
- Exposes: `Backend.makeLive(config:)` returning live implementations of `AuthService` (Sign in with Apple, email code, session refresh, sign-out, delete account), every repository, and `MediaStore` (upload with progress, image downscale to 2048 px long edge, public URLs).
- Acceptance: against local Supabase with the seed, a scratch debug screen exercises sign-in by email code, profile edit, car create with photo, friend request and accept, and each call's result prints. Every repository method is implemented or explicitly `fatalError("wave N")`-free: unimplemented later-wave repositories return empty results, never crash.

**W1-2 Gateway core**
- Goal: section 7 for a single node.
- Read: 2.5, 6, 7.
- Owns: `server/internal/{auth,ws,hub,geo,privacy,bus,store}/**` (not `bus/natsbus`).
- Exposes: `/v1/rt`; `PUT /v1/privacy`; the in-process bus; flags `-tick`, `-bench`; metrics for connections, publishes, deliveries, drops, outbox depth, flush duration.
- Acceptance: two `websocat`-style debug clients (a small Go program under `server/cmd/rtdebug`, owned here) show: friend precise delivery; approximate delivery snapped to a cell centre at most every 15 s; hidden delivers nothing; ghost flips delivery off within one tick; a nearby stranger receives no name and no heading; viewport change swaps subscriptions and sends `gone`; a stalled reader is closed with code 4008 without delaying others; `go build -race` run of a 60-second smoke scenario reports no races.

**W1-3 Realtime client and location**
- Goal: the client half of the realtime path.
- Read: 3.2, 3.3, 4.3, 6.
- Owns: `Sources/RealtimeClient/**`, `Sources/LocationKit/**`, `Sources/GatewayAPI/**`.
- Exposes: live `RealtimeService`, `LocationService`, `GatewayService`; home-zone storage (Keychain-backed file) and sending of `SetHomeZones`.
- Acceptance: with the gateway running locally and the simulator's "Freeway Drive" location, a debug screen shows connection state, round-trip time from `Ping`, updates sent per minute by state (driving, slow, stationary), and received entity count. Killing and restarting the gateway shows backoff and recovery without leaking tasks (Instruments or a task counter on the debug screen stays flat across 10 cycles).

**W1-4 Onboarding and settings**
- Read: 2.5, 10.2, 10.9, 10.10.
- Owns: `Sources/OnboardingFeature/**`, `Sources/SettingsFeature/**` (S1, S2, S5, S6; S3 and S4 arrive later and their rows stay hidden), `Sources/SafetyKit/**` limited to the terms gate X2.
- Acceptance: a new user completes O1–O4 in under 60 seconds in the simulator; every state listed for those screens is reachable; S2's three previews change live as settings change; account deletion works end to end.

**W1-5 Map**
- Read: 9.8, 10.3 (M1, M7, M8, M10), 4.3 plug-in protocols.
- Owns: `Sources/MapFeature/**`.
- Exposes: the Map tab; `LiveEntityStore`; rendering of `MapLayerProvider` items, `MapSheetSection`s, and `MapAction`s from the registry; the Friends sheet section and friend markers (this feature's own provider).
- Acceptance: 200 simulated moving markers (a debug provider) animate at 60 fps on an iPhone 16 simulator with CPU under 40% of one core; clustering, staleness stages, and selection behave as in 9.8; all M1 states reachable; markers interpolate between fixes without jumping.

**W1-6 Vehicle catalog**
- Read: 11.1.
- Owns: `tools/catalog/**`, `Sources/VehicleCatalog/**` (reader, search, updater, and the picker UI in all three modes), `ios/App/Resources/catalog.sqlite.lzfse`.
- Acceptance: the pipeline produces a catalog from live sources and prints row counts per table and the 20 makes with the most models; search for "2019 mustang gt", "wrx 2015", and "civic si" returns the right first result in under 30 ms on device-class hardware; the picker adds a car in at most 4 taps after a typed search and never shows more than one decision per step; the EPA test-car field assumption is checked and the result written into 11.1.

**W1-7 Garage and profiles**
- Read: 10.8 (G1, G2, G3, G5, G10, G11).
- Owns: `Sources/GarageFeature/**`.
- Exposes: the Garage tab; routes `profile`, `car`. In G3 the readout row and the "Mod simulator", "Run the strip", and "Enter Showdown" rows are hidden until those features report available.
- Acceptance: every state of those screens reachable against `PreviewEnvironment` and against the live backend.

**W1-INT** (alone): wire live implementations in the composition root; walk the full flow on two simulators (sign up twice, add cars, become friends, see each other move with precise and approximate settings, ghost). Fix what breaks.

End of wave 1: two people can sign up, add their real cars, friend each other, and watch each other on the map with working privacy controls.

### Wave 2: the map does things

**W2-1 Gateway: map content and convoys**
- Read: 5.3, 6 (HTTP API), 7.6.
- Owns: `server/internal/{api,convoy}/**`, one new migration for `convoys`.
- Acceptance: each endpoint in section 6 for reports, meets, and convoys works with `curl` examples recorded in `server/README.md`; a report posted by one debug client arrives as a `MapEvent` at another within one tick; merge-within-30 m and vote rules hold; convoy members receive precise positions regardless of other settings and stop receiving them on leave.

**W2-2 Meets**: Read 10.4. Owns `Sources/MeetsFeature/**`. Registers a map layer, a sheet section, a map action ("Start a meet"), routes `meet` and `createMeet`. Acceptance: E1 completes in under 20 s; all E2 states; venue notes add and display.

**W2-3 Reports**: Read 10.3 (M5, M6), 5.3. Owns `Sources/ReportsFeature/**`. Registers layer, sheet section, action. Acceptance: two-tap post with undo; vote flow; live arrival of others' reports; expiry removes pins.

**W2-4 Navigation**: Read 10.3 (M2, M3, M4), 11.5. Owns `Sources/NavigationFeature/**`. Handles route `navigate`. Acceptance: simulator "Freeway Drive" and "City Run" routes guide correctly with voice; off-route recalculation works; low-car scoring changes the preselected route when seed reports sit on the fastest one; the passenger gate hides the add button while moving.

**W2-5 Convoy**: Read 10.3 (M9), 6. Owns `Sources/ConvoyFeature/**`. Acceptance: three simulators form a convoy by code, see the shared route and gaps as time, and the regroup prompt fires when one is held back.

**W2-6 Benchmark I**: Read 8. Owns `server/cmd/loadgen/**`, `bench/**`, `docs/BENCHMARKS.md`. Acceptance: one command (`make bench-local`) runs the single-node scenarios on the Mac and writes results JSON and a table to `docs/BENCHMARKS.md`, including tick vs immediate, bytes per delivery, memory per connection at 10,000 and at the highest count the Mac sustains; any target missed is stated with the profile that explains it.

**W2-7 Safety**: Read 10.10. Owns the rest of `Sources/SafetyKit/**`, `Sources/SettingsFeature/Blocked*.swift`. Exposes live `SafetyService` (report, block, text filter with a bundled word list), X1, S4. Acceptance: blocking hides a user's markers, meets, messages, and posts everywhere immediately; reports land in `content_reports`.

**W2-INT** (alone).

End of wave 2: start and find meets, report hazards, navigate with low-car awareness, drive in a convoy. First published latency numbers.

### Wave 3: teams, voice, push, second node

**W3-1 Messaging**: Read 5.4, 10.7 (T2, T7). Owns `Sources/MessagingFeature/**`. Exposes thread and channel views through routes `channel` and `thread`; optimistic send; Realtime subscription as `AsyncStream`; read markers. Acceptance: two simulators chat with under 1 s delivery; offline send fails visibly and retries; pagination of 500 seeded messages is smooth.

**W3-2 Teams**: Read 10.7 (T1, T4, T5, T6). Owns `Sources/TeamsFeature/**`. Exposes the Teams tab and route `team`. Acceptance: create, find, join by code; roles and permissions enforce in UI and in RLS (attempting a forbidden action as a plain member fails server-side).

**W3-3 Voice**: Read 10.7 (T3). Owns `server/internal/voice/**`, `Sources/VoiceFeature/**`. Acceptance: two physical devices or one device and one simulator talk in a channel; mute default; collapsed strip persists across tabs; token endpoint refuses non-members. Needs the LiveKit keys from section 14.

**W3-4 Push**: Read 6 (`/internal/notify`), 10.9 (S3). Owns `server/internal/push/**`, `Sources/PushKitBridge/**`, `Sources/SettingsFeature/Notifications*.swift`, `ios/App/Waypoints.entitlements`, one migration for the `pg_net` triggers. Acceptance: on a physical device, each of the six notification kinds arrives and deep-links to the right screen; meets-nearby respects radius and switch; permission is requested only at the moments named in 10.2. Needs the paid Apple account and APNs key from section 14.

**W3-5 Scale-out and Benchmark II**: Read 7.5, 7.6, 8. Owns `server/internal/bus/natsbus/**`, `deploy/**`, additions under `bench/**` and `docs/BENCHMARKS.md`. Acceptance: two gateway processes plus NATS (compose file) pass the W1-2 acceptance scenarios with the two debug clients on different nodes; `make bench-cluster` produces the two-node, slow-consumer, and reconnect-storm results; `deploy/` builds one image and documents a single-VM deployment with Caddy for TLS.

**W3-INT** (alone).

End of wave 3: teams with channels, roles, and voice; direct messages; notifications; a horizontally scaled gateway with numbers.

### Wave 4: builds

**W4-1 Performance model and mod catalog**: Read 11.2. Owns `Sources/PerformanceModel/**`, `tools/mods/**`. Acceptance as stated in 11.2 (12 reference cars inside stated error; 40+ mods with sources; kits for 6 platforms).

**W4-2 Engine audio**: Read 11.3. Owns `Sources/EngineAudio/**`. Exposes `EngineSynth` (start, stop, set rpm, load, and a `SoundProfile` derived from spec and mods). Acceptance: a gallery screen with layout presets (inline-4, inline-6, cross-plane V8, flat-plane V8, boxer) and mod switches; no audio dropouts over 10 minutes with the Thread Sanitizer off and the main thread deliberately stalled; Instruments shows zero allocations on the audio thread.

**W4-3 Mod simulator**: Read 10.8 (G6), 11.2, 11.3. Owns `Sources/ModSimFeature/**`. Handles route `modSim`; turns on G3's readout row. Acceptance: toggling a mod updates chart, readouts, and sound within one frame; dependency prompts work; "Save to car" persists and reflects on G3.

**W4-4 Feed**: Read 10.5 (F1–F3). Owns `Sources/FeedFeature/**`. Acceptance: scrolling 50 seeded videos never shows a black frame longer than 200 ms on Wi-Fi; memory stays flat (players are pooled, three at most); upload survives leaving the screen.

**W4-5 Showdown**: Read 10.5 (F4, F5), 5.5. Owns `Sources/ShowdownFeature/**`. Registers the Showdown mode inside Feed through a `Core` slot (`FeedMode` provider, defined in W0-A). Acceptance: voting updates ratings through the RPC; self-votes and repeat pairs are impossible; weekly and all-time lists correct against a seeded set.

**W4-INT** (alone).

End of wave 4: simulate and hear mods on your real car, post and watch videos, judge builds.

### Wave 5: market, strip, collections, release

**W5-1 Market**: Read 10.6. Owns `Sources/MarketFeature/**`. Acceptance: list, browse with "Fits" filter, save, message seller (thread opens with the listing pinned), mark sold.

**W5-2 The Strip**: Read 10.8 (G7–G9), 11.4. Owns `Sources/RaceFeature/**`. Acceptance: a stock car's unassisted perfect-input run lands within 2% of `estimate()`'s quarter-mile midpoint; ghost replay of a stored run reproduces its time exactly; every guardrail in 11.4 is present.

**W5-3 Spots** (proposal): Read 10.3 (M12). Owns `Sources/SpotsFeature/**`. Acceptance: plate blur catches the plate in 9 of 10 varied test photos and is user-correctable; no precise coordinates are stored.

**W5-4 Roads** (proposal): Read 10.3 (M11). Owns `Sources/RoadsFeature/**`. Acceptance: record a simulated drive, save a stretch, see it on another account's map, rate it.

**W5-5 Progress**: Read 9.8. Owns `Sources/ProgressFeature/**`, one migration for achievement triggers. Completes the earned icon and trail art (adds to `DesignSystem/MapIcons/`, which no one else touches this wave). Acceptance: each key in 9.8 can be earned in a scripted scenario and unlocks its icon with the `win` moment; locked icons state exact progress.

**W5-6 Release and Benchmark III**: Read 8, 9.12, 14. Owns `ios/App/PrivacyInfo.xcprivacy`, `docs/APP_STORE.md` (listing copy, review notes explaining location use and the virtual-only racing), `docs/BENCHMARKS.md` final, `README.md`. Acceptance: accessibility pass (VoiceOver through every tab's main flow, AX5, Reduce Motion) with fixes filed to the integration package; installed size under 60 MB; final benchmark table on the reference VMs with raw results committed.

**W5-INT** (alone): fix the accessibility findings; full regression walk of section 10.

---

## 13. Waves at a glance

| Wave | Parallel packages | Usable result |
|---|---|---|
| 0 | A, then B · C · D, then INT | Builds, launches, design gallery, schema, gateway health. |
| 1 | 1–7, then INT | Sign up, add your car, friends live on the map, privacy controls. |
| 2 | 1–7, then INT | Meets, reports, navigation with low-car scoring, convoys. Benchmark I. |
| 3 | 1–5, then INT | Teams, voice, messages, push. Two-node gateway. Benchmark II. |
| 4 | 1–5, then INT | Mod simulator with sound, feed, Showdown. |
| 5 | 1–6, then INT | Market, the Strip, spots, roads, unlocks. Benchmark III. Ready to submit. |

Within a wave no two packages own the same path. Cross-package needs inside a wave go through `Core` contracts that exist from wave 0.

---

## 14. Manual actions for the owner

**Before wave 0**

1. `brew install xcodegen protobuf swift-protobuf supabase/tap/supabase nats-server` and `go install google.golang.org/protobuf/cmd/protoc-gen-go@latest`. Install Docker Desktop (the local Supabase stack needs it).
2. Decide the bundle identifier (suggestion: `app.waypoints.ios`) and tell the W0-A agent.
3. The old backend is still deployed on Render and will fail to build from `main` now that its Dockerfile is gone. Delete the Render service and any Fly.io app in their dashboards. The old Expo/EAS project (`35842cb3-…`) can be deleted at expo.dev.

**Before wave 1**

4. Create a new Supabase project (free). The old project's schema is not reused. From the dashboard copy the project URL and anon key into `ios/App/Config.xcconfig`, and the service-role key and database URL into `server/.env`. Confirm the project uses asymmetric JWT signing keys (Settings → JWT Keys), not the legacy secret.
5. Enable the email provider with one-time codes in Supabase Auth. Sign in with Apple can wait for step 7.

**Before wave 3**

6. Join the Apple Developer Program ($99/year). This is the only payment in the plan. It is required for push notifications, Sign in with Apple, TestFlight, and installs that last more than 7 days. Waves 0–2 run entirely in the simulator without it.
7. In the developer portal: register the bundle identifier with Push Notifications, Sign in with Apple, and Associated Domains; create an APNs auth key (`.p8`) and note the key id and team id for `server/.env`; configure Sign in with Apple in Supabase Auth.
8. Create a LiveKit Cloud project (free "Build" plan; about 5,000 participant-minutes a month *(verify on their pricing page)*). Put the URL, API key, and secret in `server/.env`.

**Before benchmark III and any real-device use away from your Mac**

9. A host for the gateway. Free option: Oracle Cloud "Always Free" Ampere A1 (up to 4 ARM cores and 24 GB *(verify it is still offered and available in your region; capacity is often short)*). Create two VMs of 2 cores each: one for the gateway and NATS, one for the load generator. `deploy/` documents the rest. TLS uses Caddy with a free `sslip.io` hostname, so no domain purchase is needed.
   - If Oracle is not available: run benchmark III on the Mac and label it loopback, and host the gateway on any free tier that allows WebSockets, accepting that it sleeps when idle.
10. A contact email address for the app (shown in S6 and required by App Review for apps with user content).

**Before submission**

11. Terms of Service and Privacy Policy pages at public URLs (drafts will be in `docs/APP_STORE.md`; hosting can be a free static page). App Store Connect listing, screenshots, age rating questionnaire, privacy nutrition labels (the answers are drafted in `docs/APP_STORE.md`).
12. Decide who reviews content reports and how often. App Review expects action within 24 hours.

Optional later: request the CarPlay navigation entitlement from Apple; buy a domain.

**What costs money**: only item 6. Everything else is on a free tier, with these ceilings: Supabase free pauses a project after a week without activity and caps storage near 1 GB *(verify)*, which is roughly 100 feed videos at the size limit in F3; LiveKit's free minutes; one free VM.

---

## 15. What was left out, and why

| Left out | Why |
|---|---|
| Liquid Glass and iOS 26+ APIs | iOS 18 target on the installed toolchain. The design is custom and does not depend on it. |
| Light theme | One theme done properly beats two done adequately; the product is used at night over a dark map. |
| Android, iPad layouts, Apple Watch, CarPlay, Live Activities, widgets | Each is a separate product surface. CarPlay also needs an entitlement. |
| Payments, subscriptions, currency, boosts | Not needed; their absence is a selling point. Market is listings and messages only. |
| A recommendation algorithm for the feed | Recency and likes by region is honest and enough at small scale. |
| Video transcoding and adaptive streaming | Needs paid infrastructure. Clips are capped at 30 s, 720p, 12 MB and played as progressive files. |
| End-to-end encrypted messages | Incompatible with server-side moderation of reports and with Supabase Realtime delivery; a real project of its own. |
| Live multiplayer racing | Ghost runs give the head-to-head feeling with none of the netcode. |
| Recorded engine samples | No licensable source. Synthesis is labelled as such. |
| Route generation by twistiness | Needs an OpenStreetMap processing pipeline and a routing engine; MapKit cannot be steered. Community-rated roads cover the need differently. |
| True hazard-avoiding routing | Same limit. We score Apple's alternates and say so. |
| Redis, Kafka, JetStream, a service mesh, Kubernetes | Nothing in the design needs them. One binary, optional NATS. |
| Server-side location history | Privacy position: the server does not keep tracks. |
| Automated test suites and CI | Owner's rule for now. Acceptance is by running; checks that matter (RLS, reference cars, benchmarks) are scripts and debug screens. |
| Analytics and crash SDKs | Third-party tracking contradicts the privacy position. MetricKit only. |
| Web client, admin dashboard | Reports are reviewed in the Supabase table view until volume justifies more. |

---

## 16. Carried over from the old codebase

The Expo app, the TypeScript service, and the old docs are deleted. They remain in git history: the newest version is commit `ebdce7c` (GitHub `main` before the rewrite merge). These ideas survive:

- **Location payload shape**: sequence number, latitude, longitude, speed, heading, accuracy, client timestamp. Kept, quantized, in `LocationUpdate`.
- **Presence thresholds**: stale after 10 s and offline after 30 s, driven by a periodic sweep. Kept as an idea with new numbers (9.8 staleness stages; 40 s liveness in 7.5).
- **Server-side update rate limit** (it dropped updates arriving within 900 ms). Kept at 400 ms.
- **The database is never on the realtime path; persistence is a bounded asynchronous batch queue that the hot path never awaits.** Kept as a rule; the only location-driven write is the batched `user_presence_cell` flush.
- **Supabase JWT verification against the project's JWKS, with a 10-minute key cache, checking issuer, audience, expiry, and failing closed.** The logic is reimplemented in Go in `internal/auth`.
- **Row-level security pattern**: a `security definer` helper function in a private schema to avoid recursive policies, with every lookup bound to `auth.uid()`. Reused throughout section 5.
- **`profiles` and `friendships` tables.** Kept and extended.
- **Join codes** from an alphabet without 0, O, 1, I. Kept for convoys and team invites.
- **Group ETA to a shared destination.** Became the convoy's shared route and time gaps.

- **Battery level riding the location stream**, shown as a low-battery badge on a friend. Not in the wire protocol yet; a candidate addition to `LocationUpdate` and `EntityInfo` for friends only, to be decided in wave 1 integration.
- **Arrival detection within 50 m of a destination, validated on the server.** Reused for meet check-in (200 m) and convoy arrival.
- **SOS: a durable alert whose location comes from the server's last known fix, never from the client's claim.** Not scheduled. Worth adding to convoys later; the rule about sourcing location server-side stands.
- **Load test method**: senders stamp send time, receivers measure only cross-participant deliveries, optional connection churn. Kept and extended in section 8.2. The old results are the baseline in section 7.1.
- **Per-IP rate limit on joins.** Kept for convoy and team joins.

Dropped on purpose: session rooms as the unit of sharing, the per-room event log with replay by event id (location is conflatable, so reconnect resumes from current state), JSON text frames, and peer-to-peer WebRTC voice signaling through the socket.
