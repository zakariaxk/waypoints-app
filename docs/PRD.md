# Waypoints: product requirements

Native iOS social map for the car community. Swift 6 client, Go realtime gateway, Supabase.

This document says **what** Waypoints is, what is in and out, how good it has to be, where the build stands today, and the order of the remaining work. `docs/PLAN.md` says **how** it is built: architecture, wire protocol, schema, design tokens, and the layout and copy of every screen.

Written 2026-11-13 against commit `80823e1`. Facts marked *(verify)* could not be confirmed against a primary source; the package that depends on one checks it first.

## Contents

0. How to use this document
1. Product
2. Rules that bound every decision
3. Where the project stands
4. Requirements by area
5. Requirements that cut across areas
6. What this document adds to the plan
7. Verification without a test suite
8. Roadmap and work packages (waves 6 to 9)
9. Owner's actions
10. Free-tier ceilings
11. Risks
12. Backlog, and what never ships
13. Change log

---

## 0. How to use this document

### 0.1 Order of authority

1. **This document** decides scope, behaviour, priority, status, and the order of work.
2. **`docs/PLAN.md`** decides implementation: module boundaries, contracts, schema, wire format, tokens, screen layouts, final copy.
3. **Code.**

When two of them disagree, the higher one wins and the lower one is fixed in the same commit, with a line in the commit message saying which was changed. Where this document is silent, the plan stands as written. Section 3.3 lists the disagreements known today.

Plan section 12 (waves 0 to 5) is history: those packages have been coded. All new work is a package in section 8 of this document.

### 0.2 For an agent starting a task

1. Read sections 0 and 2 here, then your package's entry in section 8 and every requirement it names in sections 4 and 5.
2. Read plan sections 1, 4, and 9.11, then the plan sections your requirements cite.
3. Do the work inside the files your package owns (section 8.1 covers shared files).
4. Prove it the way section 7 describes.
5. In the same commit, update the Status of each requirement you finished or found broken.

A task that is not a package in section 8 still names the requirement IDs it serves. If no requirement covers it, add the requirement first (section 0.5).

### 0.3 Requirement format

Every requirement has a stable ID (`MAP-4`). IDs are never renumbered or reused; a dropped requirement keeps its row with status Cut.

**Priority**

| Priority | Meaning |
|---|---|
| P0 | Needed for version 1.0. Everything in the owner's original brief, plus what App Review requires. |
| P1 | Also in version 1.0. Small additions that close a visible gap and need no new infrastructure. |
| P2 | Version 1.1. Starts only after 1.0 is on TestFlight. |

**Status**

| Status | Meaning |
|---|---|
| Coded | Code exists and compiles. Not yet proven by running. |
| Partial | Coded, with a named piece absent. The gap is written in the row. |
| Missing | Specified in the plan, absent from the code. |
| New | Introduced by this document. Not in the code. |
| Verified | Demonstrated as section 7 describes. The commit that set this says how. |
| Cut | Dropped. The row says why. |

### 0.4 Words used here

"The plan" is `docs/PLAN.md`. Screen ids such as M1, E2, G6 are the plan's (plan section 10). "The gateway" is the Go service. "The owner" is the person who owns the repository and is the only human on the project.

### 0.5 Changing this document

Anyone may fix a status. Adding, changing, or cutting a requirement is a decision: make the edit, add a line to section 13, and say so in the commit message under "PRD change:". A new requirement must pass both tests in section 2 before it is written down.

---

## 1. Product

### 1.1 What it is

One app where a car person can see who is out driving, find or start a meet, drive there together, talk to their team, show their build, and play with it: simulate mods, hear them, race the result on a virtual strip.

### 1.2 Who it is for

| Person | Arrives to | Leaves satisfied when |
|---|---|---|
| The driver | See which friends are out and where something is happening tonight. | They are navigating to it within a minute, on a route that suits a lowered car. |
| The host | Put a meet on the map and get people to it. | People nearby were told, RSVPs show which cars are coming, and the cruise left together. |
| The builder | Show the car and plan the next part. | The garage shows the real car with its timeline, and the simulator gave an honest range for the next mod and let them hear it. |
| The seller and the browser | Move a part, or find one that fits. | A listing is up in under two minutes, or results are already filtered to their car. |
| The team | Keep a club together. | Channels, voice, roles, and the team's meets are in one place. |

### 1.3 Pillars

Each borrows one proven pattern and adapts it for cars. Nothing here is invented where a working pattern exists.

| Pillar | Pattern borrowed | Areas in section 4 |
|---|---|---|
| Live map | DrivnBye, Waze | PRV, MAP, ICN, NAV, RPT, HELP |
| Meets and events | Facebook Events | MEET |
| Convoys | Shared live route | CNV |
| Teams | Discord | TEAM, MSG, VOX |
| Showdown | Tinder | SHOW |
| Profiles | Instagram | SOC |
| Feed | TikTok | FEED |
| Garage and catalog | Own design | GAR |
| Mod simulator | Own design | MOD |
| The Strip | Arcade drag racing | STR |
| Marketplace | Craigslist-simple | MKT |
| Collections | Own design | SPOT, ROAD |

### 1.4 Position

The reference competitor is LiveMap (plan 2.2). Waypoints beats it on six axes, and every requirement below is checked against them:

1. **Privacy.** Per-audience precision enforced on the server. Strangers never receive a real coordinate.
2. **Fairness.** Nothing is for sale. Rankings are votes. Icons are earned by taking part.
3. **Safety.** Nobody sees another person's speed. No reward for speed or distance. Racing is a game on a screen.
4. **Weight.** Under 60 MB installed, three client dependencies.
5. **Useful alone.** Reports, rated roads, recurring meets, and spots make the map worth opening with no friends online.
6. **Depth for builders.** A real catalog, an honest simulator, synthesized sound, and a strip driven by the same model.

It must not look generated. Plan section 9 is the design law; section 5.1 here is how it is enforced.

### 1.5 Versions

- **1.0**: every P0 and P1 requirement Verified, a build on TestFlight, the App Store submission ready.
- **1.1**: P2.

---

## 2. Rules that bound every decision

### 2.1 Product rules (never broken, never traded)

1. Location never reaches a viewer at higher precision than the publisher's settings allow. Fuzzing happens in the gateway, before data leaves the server.
2. Another person's speed is never transmitted to a client and never displayed.
3. Racing exists only as the virtual Strip. Nothing on the map refers to racing. No reward depends on real speed or real distance.
4. Nothing is for sale: no subscription, currency, boost, or paid icon. The market carries listings and messages, never payment.
5. The database is never on the realtime path.
6. The server keeps no location history. It stores one coarse cell per user.
7. Every person and every piece of user content can be reported, and every person can be blocked, from where it appears.
8. A control that does nothing is not on screen. An estimate never appears as a bare number: it carries "est." and a range.
9. No third-party analytics, advertising, or crash SDK.
10. Car makes are text. No manufacturer logos or badges.

### 2.2 The finishable-by-AI test

A requirement may exist only if an agent can build it and prove it from a terminal with what is in the repository and the free tiers. Concretely:

- **Provable by a command.** `make build`, a script that prints PASS or FAIL, a debug client, or a screenshot an agent can read (section 7). Checks that need a person holding a phone are listed once, in section 9.3, and nothing else may depend on one.
- **No hand-made assets.** Icons and artwork are vector code or drawn by a script. No stock photos, no licensed audio, no purchased fonts.
- **No licensed or scraped data.** Sources are free and public. A hand-kept data file has a source URL on every row, and the agent that adds a row opens the source rather than recalling the number.
- **No paid service** beyond the Apple Developer Program.
- **No trained models.** On-device system frameworks (Vision, AVFoundation, MapKit) only.
- **No human operations.** Nothing that needs a person on a schedule, except reviewing content reports (section 9.2).
- **One package, one session.** A package touches a few modules, ends with a passing build, and leaves the app usable.

### 2.3 The over-engineering test

Before adding anything, answer: would the app be worse without it, for a person in section 1.2, this version? If the answer is no, it is not added. In practice:

- No new service, queue, cache server, or background worker. The gateway and Postgres do the work.
- No new dependency without a row in plan 4.4. No new Swift module unless a package in section 8 says so.
- No abstraction with one caller. No option, toggle, or setting that is not a requirement here.
- No framework for feature flags, theming, analytics, experiments, or dependency injection beyond `AppEnvironment`.
- No test target, CI pipeline, or branch workflow (owner's rule). Proof is by running.
- A second way to do something that already works is a bug.

### 2.4 Workflow

Everything commits to `main`. Before committing: `git pull --rebase`, then `make build`. Commit messages start with the package id (`W6-3: reroute after 5 s off the line`). No attribution trailers.

---

## 3. Where the project stands

Audited 2026-11-13 by building, by inventory of files and endpoints, and by searching the source for each screen's final copy from plan section 10. Nothing was run against a backend, so the only requirements marked Verified are the two the compiler and a source search can prove (CONC-1, CONC-2).

### 3.1 What exists

- `make build` exits 0 with no warnings: the Go gateway and catalog tool build and vet, and the iOS app builds for the simulator in Swift 6 mode with complete concurrency checking.
- 32 Swift modules, about 19,600 hand-written lines. All 20 feature modules register themselves and report available. Features do not import each other. One `@unchecked Sendable` type exists, the audio render kernel, as the plan allows.
- The gateway (about 5,500 lines): the realtime endpoint, privacy, reports, meets, convoys, voice tokens, push, the in-process bus and the NATS bus, metrics, and a load generator.
- Ten migrations: schema, row-level security, RPCs, triggers, storage, convoys, push triggers, achievements, meet check-ins. `supabase/checks.sql` and a seed for Philadelphia and South Jersey.
- 36 vehicle silhouettes generated from a proportion table, 8 trails, a 42-entry mod catalog, the design gallery, and the B612 Mono readout face.
- One benchmark run (Benchmark I, local, 2026-11-10) in `docs/BENCHMARKS.md`.

### 3.2 What has not happened

- The app has never run against a backend. There is no `server/.env`, `ios/App/Config.xcconfig` is the local example, and the `supabase` CLI and `nats-server` are not installed on the owner's machine. Docker is running.
- No screen has been looked at. Roughly twenty thousand lines of first-pass code compile and are unproven.
- Benchmark II has scripts and no recorded results. Benchmark III has not been attempted.

So the first job is not more features. It is making what exists run, and proving it (wave 6).

### 3.3 Known gaps

Found by the audit. Each is carried by the requirement in the last column.

| Gap | Evidence | Requirement |
|---|---|---|
| Account deletion cannot work | The client calls RPC `delete_account`; no migration defines it. | ACC-10 |
| The catalog snapshot is not in the app | `ios/App/Resources/` does not exist; the app falls back to the preview seed catalog. | GAR-7 |
| No curated specs | `tools/catalog/overrides.csv` has a header and no rows, so no car has torque, redline, or gear ratios. | GAR-8 |
| Kits for one platform only | Supercharger kits exist for the 2024+ Mustang GT. The plan asked for six platforms. | MOD-2 |
| No reference-car check | `ReferenceCars.swift` and its debug screen do not exist. | MOD-13 |
| No weekly Showdown job | Nothing awards `showdown_top10` or closes a week. | SHOW-7 |
| No meet reminder | The RSVP flow never asks, and nothing schedules a notification before a meet starts. | MEET-4, MEET-6 |
| No universal links | No entitlements file, no associated domain, no landing page. Shared links are `waypoints://` only, which Messages does not make tappable. | LINK-2 |
| No app icon | The icon set has no image. | CMP-6 |
| No String Catalogs | Strings are inline in every module. | L10N-1 |
| No MetricKit | Nothing subscribes to it. | OBS-2 |
| No realtime debug client | `server/cmd/rtdebug` was never written, so the gateway's privacy behaviour has no check. | W6-A |
| "For you" is not ranked | The repository has one feed query ordered by recency. | FEED-2 |
| Units | Only navigation formats distance by locale. | SET-3 |
| Device token is never removed | `removeDeviceToken` exists; nothing calls it on sign-out. | NTF-5 |
| Video export is not HEVC | The export uses the 1280×720 H.264 preset. The 12 MB cap is unconfirmed. | FEED-7 |
| Final copy not found in the source | "Saved roads", "Search needs a connection.", "Clear for a lowered car", "Share with convoy", the hazard-ahead strip, "Offline. Follow the route line.", "Invite to convoy", "Convoy ended.", "Add to collection", "Remind you before it starts?", "Couldn't play this.", "Upcoming", "Voice disconnected.", "Edit team", "Change role". Each may be reworded or absent; the owning package confirms. | NAV-1, NAV-3, NAV-8, NAV-12, NAV-13, MAP-12, CNV-7, SPOT-5, MEET-4, FEED-8, TEAM-4, VOX-5, TEAM-8, TEAM-7 |

**Where the code and the plan differ and the code is right.** Wave 6 updates the plan to match:

| Plan says | Code does | Decision |
|---|---|---|
| The Strip is a SpriteKit scene (10.8, 11.4). | A SwiftUI `Canvas`. | Keep `Canvas`. The requirement is STR-1 and STR-7, not a framework. |
| The mod catalog is `tools/mods/mods.json`. | A Swift table in `PerformanceModel/Mods.swift`. | Keep the Swift table. |
| The font lives in `ios/App/Fonts/`. | `DesignSystem/Resources/Fonts/`. | Keep. |
| Silhouettes are hand-drawn vector assets (9.8). | Generated from proportions in code. | Keep if ICN-1 passes its screenshot check; otherwise redraw the failing ones as paths in code. |
| `VehicleCatalog` uses `GRDB.swift` (4.4). | The system `SQLite3` module. The package has three dependencies: `swift-protobuf`, `supabase-swift`, LiveKit. | Keep. One dependency fewer. |

---

## 4. Requirements by area

Each area gives its intent, its requirements, and the plan sections that hold the detail. Copy in quotes is final.

### 4.1 Accounts and onboarding (ACC)

Get from install to a car on the map with the least typing. Plan 10.2, 10.10.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| ACC-1 | Sign in with Apple. | P0 | Coded |
| ACC-2 | Sign in by email with a 6-digit one-time code that submits on the sixth digit. "Send it again" after 30 s. Wrong code and offline each have their own message. | P0 | Coded |
| ACC-3 | New users choose a handle (3 to 20 of `a-z0-9_`, unique, availability shown after 400 ms idle), a name, and a birth year. Under 17 cannot continue. | P0 | Coded |
| ACC-4 | Onboarding embeds the vehicle picker so the first car is on the marker from minute one. It can be skipped. | P0 | Coded |
| ACC-5 | A screen explains who sees you before the system location prompt, and asks the Nearby question once with Hidden preselected. | P0 | Coded |
| ACC-6 | The terms gate (six rules) appears once after profile setup and again when terms change. No user content is shown before agreement. | P0 | Coded |
| ACC-7 | Notification permission is asked only at its first reason: the first Going RSVP, the first friend request sent, or turning on meets-nearby alerts. | P0 | Partial: the RSVP prompt copy is not in the source. |
| ACC-8 | A new user finishes onboarding in under 60 seconds. | P0 | Coded |
| ACC-9 | The session survives relaunch and refreshes its token without the user noticing. Sign out returns to sign-in and clears local state. | P0 | Coded |
| ACC-10 | Delete account: explains what is deleted, requires typing the handle, deletes the auth user and every row immediately, signs out. | P0 | Coded |
| ACC-11 | A link opened while signed out continues to its target after sign-in. | P0 | Coded |

### 4.2 Privacy and location sharing (PRV)

Privacy is the product's first advantage. It is enforced on the server. Plan 2.5, 3.3, 7.4, 10.9 (S2).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| PRV-1 | Four audiences: Friends, Team members, Convoy, Nearby. Three levels: Precise (up to 1 Hz, with heading), Approximate (snapped to the centre of an H3 resolution 8 cell, no heading, at most one update per 15 s), Hidden (nothing is sent). | P0 | Coded |
| PRV-2 | Defaults: Friends Precise, Team Approximate, Nearby Hidden. | P0 | Coded |
| PRV-3 | Nearby can never be Precise, in the interface or in the database. | P0 | Coded |
| PRV-4 | The gateway computes each viewer's representation. A viewer not entitled to precise location never receives it, on any path, including across gateway nodes. | P0 | Coded |
| PRV-5 | Hidden cannot be told apart from offline. | P0 | Coded |
| PRV-6 | Ghost mode overrides everything to Hidden for 1 hour, until 6:00 tomorrow, or until turned off. It is reachable by long-press on the map avatar and in settings. | P0 | Coded |
| PRV-7 | Up to three home zones (300 m radius). Inside one, every audience is capped at Approximate and Nearby is Hidden. Zone centres are stored on the device and held by the gateway in memory only. | P0 | Coded |
| PRV-8 | Speed is used by the gateway for rate policy only and is stripped before fan-out. | P0 | Coded |
| PRV-9 | Postgres stores one H3 resolution 7 cell per user and no track history. The only database write caused by location is the batched presence-cell flush. | P0 | Coded |
| PRV-10 | Settings show a live preview of exactly what Friends, Teams, and Drivers nearby receive right now. | P0 | Coded |
| PRV-11 | A convoy is always precise while active. The join screen says so, and joining while ghost asks first. | P0 | Coded |
| PRV-12 | Background sharing is off until the user turns on "Keep sharing when the app is closed", after an explanation. It stops after 5 minutes parked. | P0 | Coded |
| PRV-13 | Blocking stops location in both directions at once. | P0 | Coded |
| PRV-14 | A privacy change takes effect for every viewer within one gateway tick. A failed save reverts the control and says "Couldn't save. Try again." | P0 | Coded |
| PRV-15 | Drive recording is opt-in and stays on the device. | P0 | Coded |

### 4.3 Live map (MAP)

The home screen: who is out, what is happening, how to get there. Plan 9.8, 10.3 (M1, M7, M8).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| MAP-1 | A full-bleed dark map. Points of interest limited to fuel, parking, EV charging, car wash, and automotive services. | P0 | Coded |
| MAP-2 | Friends at Precise appear as their car's silhouette in their paint colour with their name, moving continuously between fixes and turning to heading. | P0 | Coded |
| MAP-3 | Approximate friends and teammates appear at 60% opacity inside a dashed ring, with no rotation. | P0 | Coded |
| MAP-4 | Nearby strangers appear as small unlabelled markers with no name, car, or profile. Their peek explains why. | P0 | Coded |
| MAP-5 | Markers age: the live ring stops after 60 s without a fix, the marker dims after 5 minutes, and it is removed after 30. | P0 | Coded |
| MAP-6 | Crowded markers cluster into a count. You and a selected friend never cluster. | P0 | Coded |
| MAP-7 | Zoomed out, individual markers give way to cell counts with "Zoom in to see drivers." | P0 | Coded |
| MAP-8 | A bottom sheet with three detents carries a one-line summary and sections for Friends, Meets, the active convoy, and Reports nearby. Selecting a row or marker centres the camera and shows its detail. | P0 | Coded |
| MAP-9 | One add button opens a menu of actions at the map centre: report a hazard, start a meet, start a convoy, spot a car. Long-press on the map opens the same menu at that point. | P0 | Coded |
| MAP-10 | Recenter cycles between free, following, and heading-up. Tapping the Map tab again recenters. | P0 | Coded |
| MAP-11 | Layers: Friends, Drivers nearby, Meets, Reports, Rated roads, Traffic. | P0 | Coded |
| MAP-12 | A friend's peek shows distance and bearing, and offers Directions, Message, View profile, Invite to convoy, Remove friend, Block, Report. | P0 | Coded |
| MAP-13 | Every state is designed: location off, nobody around, connecting (last snapshot at 50%), reconnecting (banner after 3 s), offline. | P0 | Coded |
| MAP-14 | 200 moving markers animate at 60 fps on an iPhone 16 simulator using under 40% of one core. | P0 | Coded |
| MAP-15 | Everything on the map is also reachable as a list in the sheet, for VoiceOver. | P0 | Coded |
| MAP-16 | The add button is hidden above 8 km/h unless a passenger confirms. | P0 | Coded |

### 4.4 Markers and unlocks (ICN)

The gamified icon set. Earned by taking part, never bought, never for speed or distance. Plan 9.8, 10.3 (M10).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| ICN-1 | 16 free vehicle silhouettes. Each is told from the others at 28 pt by proportion alone, and is filled with the owner's paint colour. | P0 | Coded |
| ICN-2 | 20 earned silhouettes and 7 earned trails. | P0 | Coded |
| ICN-3 | Every unlock has one requirement, stated in plain words, that rewards taking part: meets attended and hosted, reports confirmed, cars spotted, roads rated, timeline entries, votes cast, convoys led, virtual runs. The key table is plan 9.8 plus `ProgressFeature.unlocks`. | P0 | Coded |
| ICN-4 | The marker picker shows a live preview, the icon and trail palettes, and for each locked item its requirement and exact progress ("Rally: get 10 reports confirmed. You're at 6."). There is no purchase path and no "coming soon". | P0 | Coded |
| ICN-5 | Earning an unlock shows it once in the map sheet with "Use it". | P0 | Coded |
| ICN-6 | Unlocks are awarded by database triggers, by the gateway for those that need presence (meet check-ins, convoys), and by the weekly Showdown close. | P0 | Partial: the weekly close does not exist (SHOW-7). |
| ICN-7 | A profile shows the icons its owner has earned. | P1 | Coded |

### 4.5 Search, routes, and navigation (NAV)

Waze-grade guidance built on MapKit, with the one thing nobody else has: routes scored for a low car. Plan 10.3 (M2 to M4), 11.5.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| NAV-1 | Search finds places, people, and meets. Before typing it offers the last 5 recents, up to 3 meets tonight, and up to 3 saved roads. Offline it shows recents and says "Search needs a connection." | P0 | Coded |
| NAV-2 | Route preview draws up to three routes with time, distance, and main road. | P0 | Coded |
| NAV-3 | Low-car routing. Each car has a clearance profile. For a lowered or slammed car, each route lists the reports that matter along it ("2 speed bumps, 1 steep entrance") or reads "Clear for a lowered car". Among routes within 20% of the fastest, the one with the fewest is preselected and labelled "Best for your car". When none is clean, the screen says Apple Maps routing cannot be steered around them. | P0 | Coded |
| NAV-4 | Tapping the car in route preview switches which garage car is being scored. | P0 | Coded |
| NAV-5 | Guidance shows the next maneuver, the distance to it, and the road name; the following maneuver when it is within 300 m; a heading-up, pitched, following map. | P0 | Coded |
| NAV-6 | Spoken guidance at 800 m, 200 m, and at the maneuver, built from our own templates in the locale's units, ducking other audio. Mute persists. | P0 | Coded |
| NAV-7 | Leaving the route (40 m off for 5 s) recalculates without asking. At most one request per 8 s. | P0 | Coded |
| NAV-8 | For a non-stock car, a clearance report within 250 m ahead shows a strip ("Speed bump in 250 ft"), one haptic, and one spoken line. | P0 | Coded |
| NAV-9 | Your own speed appears on your navigation screen and nowhere else. | P0 | Coded |
| NAV-10 | Arrival reads "You've arrived" and ends guidance after 10 s. | P0 | Coded |
| NAV-11 | While moving, the only controls are mute, End, and the "Still there?" prompt. | P0 | Coded |
| NAV-12 | Offline, guidance continues on the loaded route and reads "Offline. Follow the route line." when it cannot reroute. | P0 | Coded |
| NAV-13 | With a convoy active, route preview offers "Share with convoy". | P0 | Coded |
| NAV-14 | Directions is offered wherever a place appears: a friend, a meet, a road, a regroup point, a help request. | P0 | Coded |
| NAV-15 | Share ETA. While navigating, the user can send chosen friends one notice with the destination name and arrival time. No position is shared. Navigating to a meet you are Going to shows you as "on the way" in its list. | P2 | New |

### 4.6 Community reports (RPT)

The map is useful with nobody online. Plan 5.3, 10.3 (M5, M6).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| RPT-1 | Eight kinds: speed bump, steep entrance, pothole, rough road, police, hazard, closure, E85 fuel. | P0 | Coded |
| RPT-2 | Posting takes two taps: add, then the kind. An optional note (120). A toast offers Undo; the author can remove a report for 5 minutes. | P0 | Coded |
| RPT-3 | Lifetimes: police 45 minutes, hazard 2 hours, closure 24 hours, each extended by "Still there"; pothole and rough road 90 days; speed bump, steep entrance, and E85 permanent. | P0 | Coded |
| RPT-4 | A report within 30 m of an existing one of the same kind counts as a confirmation, not a duplicate. | P0 | Coded |
| RPT-5 | Anyone can vote "Still there" or "Gone". Two Gone votes with no later Still there remove it. | P0 | Coded |
| RPT-6 | A new, changed, or removed report reaches everyone viewing that area within one gateway tick. | P0 | Coded |
| RPT-7 | Passing a temporary report while navigating asks "Still there?" for 8 seconds. | P0 | Coded |
| RPT-8 | The shape of a report's badge encodes its severity, so colour is not the only signal. | P0 | Coded |
| RPT-9 | Two more kinds: speed camera and red-light camera, permanent and confirmable like a speed bump. There is no checkpoint kind and never will be (App Review guideline 1.4.4 *(verify)*). | P1 | New |

### 4.7 Help requests (HELP)

A driver who is stuck asks the people who would actually come. Nobody in this space ships it. Introduced by this document.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| HELP-1 | From the add menu, "Ask for a hand" posts a help request at your position with one of five kinds: flat tire, jump start, out of fuel, stuck, something else. Optional note (120). | P1 | New |
| HELP-2 | It is shown to friends and teammates with your name and car. A switch, off by default, also shows it to drivers nearby as "A driver needs a hand" with no name. | P1 | New |
| HELP-3 | The sheet says, before posting: "This shares your exact spot with the people you pick until you clear it. For an emergency, call emergency services." | P1 | New |
| HELP-4 | Friends and teammates within 25 km are notified. | P1 | New |
| HELP-5 | A viewer can tap "On my way"; the requester is told who is coming. Directions is offered. | P1 | New |
| HELP-6 | It ends when the requester taps "I'm good", or after 60 minutes unless extended. One active request per person. | P1 | New |
| HELP-7 | Home zones do not apply to a help request (the user chose to share the spot), and the sheet says so when posting from inside one. | P1 | New |

Build note: a table `help_requests`, gateway endpoints beside the reports ones, and a third `MapEvent.Kind`. Delivery to friends and teammates uses the per-user subjects that already exist; only the opt-in nearby form goes to the cell.

### 4.8 Meets and events (MEET)

Anyone drops a meet on the map in three fields, from a full show to "Wawa and chill", and the people nearby hear about it. Plan 5.3, 10.4.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| MEET-1 | Starting a meet takes under 20 seconds: a pin, a title (50), one of five kinds (meet, cruise, hangout, track day, show), a time ("Now", "Tonight 8 PM", or picked), and who can see it (everyone, friends, or a team). End time defaults to 2 hours later. | P0 | Coded |
| MEET-2 | People whose last coarse cell is within their own alert radius (5 to 50 km, default 15) and who have meets-nearby alerts on are notified of a new public meet. | P0 | Coded |
| MEET-3 | Three meets per person per day. | P0 | Coded |
| MEET-4 | RSVP is Going, Maybe, or Can't. Going asks once which car you are bringing and whether to be reminded. | P0 | Coded |
| MEET-5 | "Who's going" shows cars, not faces, with a count and a full list. | P0 | Coded |
| MEET-6 | A reminder arrives 30 minutes before a meet you are Going to, if you said yes to being reminded. A local notification scheduled on the device; no server job. | P0 | Coded |
| MEET-7 | Venue notes: entrance (flat, moderate, steep), lot size, lit or not, and a note, added by anyone. | P0 | Coded |
| MEET-8 | A meet offers Directions, Share, Add to Calendar, and Report. Its host can edit or cancel it; people who RSVP'd are told of a time change or a cancellation. | P0 | Coded |
| MEET-9 | During its window a meet reads "Happening now". People with a Going RSVP within 200 m count as checked in. | P0 | Coded |
| MEET-10 | Meets appear as pins with their start time, in the map sheet sorted by start, and in search. There is no separate list screen. | P0 | Coded |
| MEET-11 | A member with the host-meets permission can start a team-only meet. A team's page lists its meets. | P0 | Coded |
| MEET-12 | Recurring meets. A host can make a meet repeat weekly, every two weeks, or monthly on the same weekday. When one occurrence ends the next is created. RSVPs do not carry over; people who checked in last time are told once. Cancelling asks "This meet" or "This and every one after". | P1 | Coded |
| MEET-13 | Roll out. A cruise can carry a destination or a saved road. At start time its host sees "Roll out", which starts a convoy named for the meet with that route and invites everyone Going. | P1 | Coded: a destination place; a saved road is not offered yet. |
| MEET-14 | People's choice. During a show or meet, each person checked in can pick one car from those brought. When it ends, the meet shows the winner and the car's timeline gains a line. | P2 | New |

### 4.9 Convoys (CNV)

Drive together and stay together. Plan 6, 7.6, 10.3 (M9).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| CNV-1 | Starting a convoy takes a name and an optional destination and returns a 6-character code, a share link, and a friend picker that sends invites. | P0 | Coded |
| CNV-2 | Joining by link or code first shows "Everyone in the convoy sees your exact location until you leave." | P0 | Coded |
| CNV-3 | There is no member cap. | P0 | Coded |
| CNV-4 | Members are listed in road order with their gap to the leader as time ("+40 s"), never speed. | P0 | Coded |
| CNV-5 | The shared route is drawn for everyone, and the leader's marker is marked. | P0 | Coded |
| CNV-6 | Regroup. When the last member has been more than 3 minutes behind the leader for 60 s, the leader is asked "The group has split. Set a regroup point?" Accepting drops a pin at the nearest fuel or parking point on the route within 3 km, or the leader's position, and every member sees "Regroup at <place>" with Directions. | P0 | Coded |
| CNV-7 | The leader can change the destination and end the convoy (with a confirmation naming the driver count). Others see "Convoy ended." | P0 | Coded |
| CNV-8 | A member who loses signal reads "Lost signal" and ages like any marker. | P0 | Coded |
| CNV-9 | Precise positions flow only while a member is in the convoy and stop the moment they leave. | P0 | Coded |
| CNV-10 | A convoy survives a gateway restart or a move to another node. | P0 | Coded |
| CNV-11 | Every convoy has voice. "Talk" opens the voice sheet for the convoy's own room; you join muted; the room ends with the convoy. This replaces the plan's team-only Talk button. | P1 | Coded |

### 4.10 Friends, follows, and profiles (SOC)

A person plus their garage. Plan 5.1, 10.8 (G1, G2, G10, G11).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SOC-1 | Find people by handle. Send, accept, decline, and remove friend requests. | P0 | Coded |
| SOC-2 | Friendship is mutual and is what location sharing is built on. Following is one-way and affects only the feed. | P0 | Coded |
| SOC-3 | Your profile is the top of the Garage tab: avatar, name, bio, home region, and counts of friends, followers, and cars spotted. | P0 | Coded |
| SOC-4 | Someone else's profile offers Add friend (then Requested, then Friends), Follow, and Message, with Share profile, Block, and Report in the overflow. | P0 | Coded |
| SOC-5 | A profile shows its cars as cards and its posts as a three-column grid. | P0 | Coded |
| SOC-6 | Edit profile: avatar with circular crop, name, handle, bio, home region. | P0 | Coded |
| SOC-7 | "Invite a friend" shares a link to your profile. | P0 | Coded |
| SOC-8 | A blocked or blocking profile reads "This profile isn't available." | P0 | Coded |
| SOC-9 | Meet-in-person adding. "My code" shows a QR code of your profile link; "Scan" in Friends reads one and opens the profile. A team's invite shows a QR code too. | P1 | Coded |

### 4.11 Garage and vehicle catalog (GAR)

Every car, chosen without clutter. Plan 5.2, 10.8 (G3 to G5), 11.1.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| GAR-1 | The catalog covers US-market passenger vehicles from model year 1981 to 2027 for about 90 makes, built from NHTSA vPIC and EPA data. | P0 | Coded |
| GAR-2 | The catalog also covers what the federal data does not: classics before 1981 and popular grey-market imports. A hand-kept `tools/catalog/supplement.csv` adds at least 300 models with their year spans. | P0 | New |
| GAR-3 | No car is ever blocked. Make, model, and trim each end with "Mine isn't listed" leading to a short free-text form, and the car is stored as text. | P0 | Partial: the plan and code offer it at the trim step only. |
| GAR-4 | The picker asks one question at a time, records answers as tappable tokens, and keeps a search field on every step that parses "2019 mustang gt" in any order into at most 8 direct matches in under 30 ms. A typed search adds a car in at most 4 taps. | P0 | Coded |
| GAR-5 | Steps: make (12 popular, then A to Z, text only), model (current first), year (a strip grouped by generation, not a wheel), trim (skipped when there is one), colour (16 families, an exact-colour wheel, an optional paint name with suggestions from other owners of that make). | P0 | Coded |
| GAR-6 | "Use VIN" scans or accepts 17 characters and lands on the resolved step. | P0 | Coded |
| GAR-7 | A catalog snapshot ships inside the app and the picker never waits on the network. A newer catalog is checked for at most daily and swapped in on the next launch. | P0 | Partial: the build does not put the snapshot in the app. |
| GAR-8 | Curated specs for at least 150 enthusiast model-generations: trim names, power, torque, curb weight, redline, gear ratios. Every row has a source URL. | P0 | Missing: `overrides.csv` has no rows. |
| GAR-9 | A car's page shows its photos, name, four readouts with ranges (est. hp, est. torque, 0 to 60, quarter mile), its build timeline, and a specs table marking each value "stock" or "edited". | P0 | Coded |
| GAR-10 | A garage holds several cars in a chosen order. The primary car sets your marker's paint colour and your car label. | P0 | Coded |
| GAR-11 | Timeline entries carry a date, a title (60), details (500), one photo, and optionally a linked mod, which adds that mod to the car. | P0 | Coded |
| GAR-12 | Each car has a clearance profile (stock, lowered, slammed) that drives NAV-3. | P0 | Coded |
| GAR-13 | Every spec can be overridden by the owner. | P0 | Coded |
| GAR-14 | Someone else's car shows its owner and "Message about this car". | P0 | Coded |
| GAR-15 | Share build. A car's overflow renders a card (lead photo, name, the four estimates marked "est.", handle) to the share sheet. | P1 | Coded |
| GAR-16 | Service log. A timeline entry can be marked as service with an odometer reading and an optional reminder date, delivered as a local notification. | P2 | New |

### 4.12 Mod simulator (MOD)

See and hear what a part does to your car, honestly. Plan 10.8 (G6), 11.2, 11.3.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| MOD-1 | A catalog of at least 40 generic mods across intake, exhaust, tune, forced induction, fuel, and weight. Each has a low and a high gain, a confidence (measured, claimed, typical), and a source URL. | P0 | Coded |
| MOD-2 | Platform kits with the maker's own figures for at least six platforms. The 5.0 Mustang is covered for 2011 to 2014, 2015 to 2023, and 2024 on, each with Whipple and Roush kits. Every figure has a source URL that was opened, not recalled. | P0 | Partial: 2024+ Mustang GT only. |
| MOD-3 | Gains do not simply add. Breathing parts saturate, a tune multiplies, a part that needs a tune gives a quarter of its gain without one, and a kit replaces both with its own figure. | P0 | Coded |
| MOD-4 | A longitudinal simulation turns power, weight, gearing, and drivetrain into 0 to 60, quarter-mile time, and trap speed. Every output is a range from the low and high ends, widened when it disagrees with the Hale formulas by more than 12%. | P0 | Coded |
| MOD-5 | A dyno chart shows stock and modified power and torque. Dragging across it scrubs rpm with a tick each 500 rpm, and the sound follows. | P0 | Coded |
| MOD-6 | Four readouts show the change from stock with its range. The line "Estimates. Real results depend on the tune, the dyno, and the day." is always visible. | P0 | Coded |
| MOD-7 | A mod that needs another says so and offers to add it. Conflicting mods cannot both be on. | P0 | Coded |
| MOD-8 | Synthesized exhaust. Pulses follow the engine's real firing order (cross-plane and flat-plane V8, inline-4, inline-6, boxer), through pipe and muffler models, with intake, supercharger whine, turbo whistle, blow-off, and overrun crackle layers. | P0 | Coded |
| MOD-9 | Mods change the sound in the right direction: cat-back louder and brighter, muffler delete more so, resonator delete raspier, headers brighter, a supercharger whines, a turbo whistles and softens the pulses, a burble tune crackles. | P0 | Coded |
| MOD-10 | "Hold to rev" sweeps rpm through first gear and lets it fall. The switch is labelled "Synthesized sound". | P0 | Coded |
| MOD-11 | "Save to car" writes the mod list and offers to add a timeline entry. | P0 | Coded |
| MOD-12 | A car without specs asks for power and weight and then simulates. | P0 | Coded |
| MOD-13 | The model is checked against 12 stock cars with published times: trap speed within 3%, quarter-mile time within 5%, 0 to 60 within 0.4 s. A debug screen lists model output beside the published figure. | P0 | Missing |
| MOD-14 | Everything works offline, and toggling a mod updates chart, readouts, and sound within one frame. | P0 | Coded |

### 4.13 The Strip (STR)

A virtual drag strip driven by your real build. Plan 10.8 (G7 to G9), 11.4.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| STR-1 | Quarter-mile runs in a landscape side view: two lanes, a tree, a tachometer with shift light, and the gear. | P0 | Coded |
| STR-2 | Skill is reaction time, launch rpm, and shift timing. Leaving before green is a red light. | P0 | Coded |
| STR-3 | The car's performance comes from its garage specs and mods through the same model as the simulator, stepped at 240 Hz, with its engine sound. | P0 | Coded |
| STR-4 | Opponents: your best run, a friend's stored run replayed from its inputs, or one of three house cars. | P0 | Coded |
| STR-5 | A time slip shows reaction, 60 ft, eighth-mile and quarter-mile time and speed for both lanes. It can be shared as an image printed with "Virtual run · Waypoints". Past runs are kept. | P0 | Coded |
| STR-6 | Guardrails, all mandatory: the word "virtual" in the lobby, on the slip, and on shared images; nothing on the map refers to racing; the feature reads no GPS, speed, or location; no challenge can name a place or a time; no taunts, no wagers, no public leaderboard of times. | P0 | Coded |
| STR-7 | Runs are deterministic: replaying a stored run reproduces its time exactly, and a perfect-input run lands within 2% of the simulator's quarter-mile midpoint. | P0 | Coded |
| STR-8 | A two-finger tap pauses: Resume, Restart, Quit. | P0 | Coded |
| STR-9 | The ladder. Ten house cars from a 16.5 s car to an 8.9 s car, described by plain specs. Beating one opens the next. A choice of sportsman or pro tree. | P1 | New |
| STR-10 | Bench race. Any car in the catalog, stock or with chosen mods, can be picked as the opponent. | P2 | New |

### 4.14 Teams (TEAM)

Servers for car clubs. Plan 5.4, 10.7 (T1, T4 to T6).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| TEAM-1 | Starting a team takes an icon, a name (40), a unique tag (2 to 5 letters), an about line, and whether anyone can find it. It is created with Owner and Member roles, a `general` text channel, and a `Garage` voice channel. | P0 | Coded |
| TEAM-2 | Find public teams, sorted by members in your region, or join by invite code or link. | P0 | Coded |
| TEAM-3 | A left rail holds direct messages, your teams, and a button to find or start one. | P0 | Coded |
| TEAM-4 | A team shows its text channels with unread counts, its voice channels with who is in them, and its next meet under "Upcoming". | P0 | Partial: "Upcoming" and channel unread counts are coded; voice rows do not yet show who is in them (no voice presence API in Core). |
| TEAM-5 | Roles have a name, a colour, a rank, and six permissions: manage team, manage channels, manage roles, kick, delete messages, host meets. The database enforces them, not only the interface. | P0 | Coded |
| TEAM-6 | Channels can be added, renamed, reordered, and deleted by those permitted. | P0 | Coded |
| TEAM-7 | Members are listed by role. Those permitted can change a member's role or remove them. | P0 | Coded |
| TEAM-8 | A team's page offers Invite people, Members, Meets, and, when permitted, Channels, Roles, and Edit team. Members can leave; the owner deletes by typing the team's name. | P0 | Coded |
| TEAM-9 | Teammates see each other on the map at the level each chose for Teams. | P0 | Coded |
| TEAM-10 | Only the Teams tab carries an unread count. | P0 | Coded |

### 4.15 Messaging (MSG)

Channels and direct messages. Plan 5.4, 10.7 (T2, T7).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| MSG-1 | Messages are bottom-anchored, grouped by author within 5 minutes, with day dividers. | P0 | Coded |
| MSG-2 | A sent message appears at once and arrives for others in under a second. A failed one reads "Not sent. Tap to retry." | P0 | Coded |
| MSG-3 | A message can carry one image. | P0 | Coded |
| MSG-4 | Long-press offers Copy, Reply (quoting the first line), Delete (your own, or with permission), and Report. | P0 | Coded |
| MSG-5 | Typing "@" lists members; a mention notifies that member. | P0 | Coded |
| MSG-6 | Older messages load on pull, smoothly through at least 500. | P0 | Coded |
| MSG-7 | Read position is kept per channel and thread and drives unread counts. | P0 | Coded |
| MSG-8 | Direct messages between two people. A thread about a listing pins that listing at the top. A first message from someone who is not a friend lands in Requests with Accept and Block. | P0 | Coded |
| MSG-9 | Text passes the safety filter before sending; a blocked message reads "That message can't be sent." | P0 | Coded |
| MSG-10 | Offline, the composer is disabled and messages already loaded stay readable. | P0 | Coded |

### 4.16 Voice (VOX)

Talk while driving, hands off. Plan 10.7 (T3).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| VOX-1 | Voice channels run on LiveKit. The gateway issues a token only to members. | P0 | Coded |
| VOX-2 | Voice opens as a sheet over wherever you are and collapses to a strip above the tab bar that persists across tabs. | P0 | Coded |
| VOX-3 | You join muted ("You're muted. Tap to talk."). Microphone permission is asked on the first unmute. | P0 | Coded |
| VOX-4 | A speaking participant is ringed. Controls: mute, audio route, Leave. | P0 | Coded |
| VOX-5 | Connecting, reconnecting (up to 15 s, then "Voice disconnected."), microphone denied, and free minutes exhausted each have their own state. | P0 | Coded |
| VOX-6 | Voice continues in the background and under navigation prompts. | P0 | Coded |

### 4.17 Feed (FEED)

Watching builds, full screen. Plan 5.5, 10.5 (F1 to F3).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| FEED-1 | A full-screen vertical pager of videos. Autoplay, muted until the user unmutes once per session, looping, with the next video's first 2 seconds preloaded. | P0 | Coded |
| FEED-2 | Three modes: Following, For you, Showdown. For you is recency plus likes within the user's region, then everywhere. No hidden algorithm is claimed. | P0 | Coded |
| FEED-3 | Over each video: author, Follow, a two-line caption that expands, and the tagged car, which opens its page. | P0 | Coded |
| FEED-4 | Like (also by double-tap), comment, and share, each with a count where it has one. | P0 | Coded |
| FEED-5 | Long-press offers Not interested, Report, and Block. | P0 | Coded |
| FEED-6 | Comments open in a sheet. You can delete your own; a post's author can delete any on it. | P0 | Coded |
| FEED-7 | Posting takes three steps: pick or record, trim anything over 30 s, add a caption (150), tag a car, choose the cover frame. The clip is exported to HEVC 720p under 12 MB and uploaded while the user goes elsewhere. A failed upload is kept as a draft. | P0 | Coded |
| FEED-8 | Empty Following, empty region, a video that will not play ("Couldn't play this." with "Try again"), and offline each have their own state. | P0 | Coded |
| FEED-9 | Scrolling 50 videos on Wi-Fi never shows a black frame longer than 200 ms, with at most three players alive and flat memory. | P0 | Coded |
| FEED-10 | You can delete your own post. | P0 | Coded |
| FEED-11 | Photo posts. A post can be up to 6 photos instead of a video, swiped sideways inside the same pager. A post can also tag a meet, and the meet shows posts from it. | P2 | New |

### 4.18 Showdown (SHOW)

Two builds, pick one. Plan 5.5, 10.5 (F4, F5).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SHOW-1 | An owner enters a car with at least one photo into one class: Street, Built, Show, or Classic. They can withdraw it. | P0 | Coded |
| SHOW-2 | Two cars fill the screen. Tap or drag one to pick it; the winner expands and shows its rank movement, then the next pair arrives. | P0 | Coded |
| SHOW-3 | Pairs are the same class, within 150 rating points, never your own car, never a pair you have judged. | P0 | Coded |
| SHOW-4 | Votes apply Elo (K = 24) on the server. A vote for your own car, or a repeat, is refused by the server. | P0 | Coded |
| SHOW-5 | Skip is always offered. Opening a car returns to the same pair. | P0 | Coded |
| SHOW-6 | Rankings by class for this week and all time, with your own cars pinned at the top. | P0 | Coded |
| SHOW-7 | The week closes on Monday at 00:00 UTC. The top 10 of each class earn `showdown_top10`. A scheduled Postgres function does it. | P0 | Coded: needs pg_cron enabled on the project. |
| SHOW-8 | When there is nobody left to judge: "You've judged every pair in Street. Try another class." | P0 | Coded |

### 4.19 Marketplace (MKT)

Parts and cars. Listings and messages, never payment. Plan 5.5, 10.6.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| MKT-1 | Browse parts or cars with search. Parts are filtered by default to what fits your active car ("Fits: 2019 Mustang GT"), which can be changed or cleared. Further filters: price, condition, distance. | P0 | Coded |
| MKT-2 | A listing shows photos, title, price, condition, region, what it fits, a description, and its seller. "Message seller" opens a thread with the listing pinned and "Is this still available?" prefilled. Listings can be saved. | P0 | Coded |
| MKT-3 | Listing something is one scrolling screen: up to 8 photos in a chosen order, part or car, title (70), price, condition, what it fits (or a car from your garage, which prefills everything), description (1500), region. | P0 | Coded |
| MKT-4 | "Yours" holds what you are selling and what you saved. A listing can be edited, marked sold, or removed. | P0 | Coded |
| MKT-5 | Every listing carries "Meet in a public place. Waypoints doesn't handle payment." | P0 | Coded |
| MKT-6 | There is no checkout, shipping, fee, or promoted placement. | P0 | Coded |
| MKT-7 | Parts have a category: wheels and tires, exhaust, intake and fuel, forced induction, engine, drivetrain, suspension, brakes, exterior and aero, interior, lighting, electronics and tuning, tools, apparel, other. Browse filters by it. | P1 | Coded |
| MKT-8 | Wanted. A third listing kind for something you are looking for, with a budget instead of a price. Shown under its own switch position. | P1 | Coded |
| MKT-9 | A listing untouched for 90 days leaves browse and reads "Expired" to its seller, with "Relist". | P2 | New |

### 4.20 Car spotting (SPOT)

A collection game on the street. Plan 10.3 (M12).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SPOT-1 | "Spot a car" opens the camera directly. | P0 | Coded |
| SPOT-2 | Licence plates are found and blurred on the device before anything is uploaded. The user can add or remove blur boxes. The blur catches the plate in 9 of 10 varied photos. | P0 | Coded |
| SPOT-3 | The car is tagged from the catalog with the picker in model-only mode. | P0 | Coded |
| SPOT-4 | Only a city name and a coarse cell are stored. No precise position, and no photo metadata. | P0 | Coded |
| SPOT-5 | The spot joins a collection grouped by make, then model, with counts and the moment "Porsche 911 · 3rd spotted". | P0 | Coded |
| SPOT-6 | Faces are blurred the same way as plates. | P1 | Coded |

### 4.21 Road ratings (ROAD)

Good roads, rated by people who drove them. Plan 10.3 (M11).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| ROAD-1 | With drive recording on, recent drives are listed in Garage. Opening one lets the user mark a stretch with two handles, name it (50), rate surface, scenery, and traffic from 1 to 5, and save it. | P0 | Coded |
| ROAD-2 | Only the saved stretch is uploaded. | P0 | Coded |
| ROAD-3 | A stretch cannot start or end inside one of the user's home zones. | P0 | New |
| ROAD-4 | Rated roads draw on the map as a layer. A road's sheet shows its length, three averages with the count, "Drive it" (routes to its start, then along it), and "Rate". | P0 | Coded |
| ROAD-5 | Driven map. On the device only, the share of road cells in your region you have driven, shown as a number and a map shading. It rewards exploring, never speed or distance. | P2 | New |

### 4.22 Notifications (NTF)

Told when it matters, at the moment it has a reason. Plan 6, 10.9 (S3).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| NTF-1 | Six kinds, each with its own switch: meets near me (with a radius), friend requests, messages, mentions, convoy invites, meet reminders. | P0 | Coded |
| NTF-2 | The gateway sends directly to APNs. Database events reach it through a trigger with a shared secret. | P0 | Coded |
| NTF-3 | Tapping a notification opens the thing it is about. | P0 | Coded |
| NTF-4 | When system permission is off, the settings screen says so and links to Settings. | P0 | Coded |
| NTF-5 | The device token is registered after permission is granted and removed on sign-out. | P0 | Coded |
| NTF-6 | Activity. A bell in the Garage bar opens a list of what happened to you: friend requests and acceptances, likes, comments, mentions, RSVPs to your meet, changes to meets you are going to, convoy invites, unlocks earned, help responses. Each row opens its subject. Kept 90 days. The bell carries an unread dot. | P1 | Partial: coded except help responses, which wait for the HELP tables. |
| NTF-7 | Restraint. One notification per event, never a marketing push, and at most three meets-nearby alerts per person per day. | P1 | Coded |

Build note for NTF-6: a `notifications` table written by the same triggers and gateway calls that push today, read by the client with row-level security. The screen lives in `PushKitBridge`, which becomes the notifications module. It works with no Apple account, so the app is coherent in the simulator.

### 4.23 Safety and moderation (SAFE)

Required by App Review for any app with user content, and by the kind of place this should be. Plan 10.10.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SAFE-1 | Every person, post, comment, message, listing, meet, map report, spot, road, car, and team can be reported, with a reason (spam, harassment, nudity, dangerous driving, scam, something else) and an optional note. | P0 | Coded |
| SAFE-2 | A person can be blocked from their profile, from the map, and from any message. Their content, markers, and messages disappear for the blocker at once, in both directions. Blocked people are listed in settings with Unblock. | P0 | Coded |
| SAFE-3 | A reported item disappears for the person who reported it. | P0 | Coded |
| SAFE-4 | A text filter with a bundled word list runs on messages, comments, captions, titles, names, and handles before they are sent. | P0 | Coded |
| SAFE-5 | Reports land in `content_reports`. The owner reviews them within 24 hours (section 9.2). | P0 | Coded |
| SAFE-6 | Content reported by three different people within 7 days is hidden from everyone but its author until reviewed. | P0 | Coded |
| SAFE-7 | A person can be suspended. A suspended account cannot connect to the gateway or write anything, and its content is hidden. Signing in shows "This account is suspended." with the contact address. | P0 | Partial: a gateway connection already open stays up until its next token refresh. |
| SAFE-8 | The reviewer works from the Supabase SQL editor with four documented functions: hide, restore, suspend, unsuspend. No admin app. | P0 | Coded |
| SAFE-9 | Abuse limits, enforced on the server: 3 meets a day, 10 map reports in 10 minutes, 3 help requests a day, 10 posts a day, 30 comments an hour, 10 listings a day, 30 friend requests a day, 3 teams a day, 20 content reports a day, 5 messages in 5 seconds. Over a limit the client says "You're doing that a lot. Try again in a few minutes." | P1 | Partial: the gateway limits help requests to 6 an hour, not 3 a day; map reports are limited per gateway node in memory; only SafetyKit shows the copy, other features still show their generic error on `rateLimited`. |
| SAFE-10 | Minimum age 17, asked at sign-up. | P0 | Coded |
| SAFE-11 | The contact address is shown in About and in the suspension message. | P0 | Coded |

### 4.24 Settings (SET)

Plan 10.9.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SET-1 | Settings holds Privacy and location, Notifications, Blocked people, Account, and About (version, Terms, Privacy Policy, Contact, licences). Debug builds add the design gallery. | P0 | Coded |
| SET-2 | Every change saves at once. A failed save reverts the control and says why. | P0 | Coded |
| SET-3 | Distances, speeds, and weights follow the device's locale everywhere they appear. | P0 | Partial: navigation and the map format distance and speed by locale; other features not checked. |

### 4.25 Links and sharing (LINK)

Growth here is one person sending a link to another. Plan 10.10 (X3).

| ID | Requirement | Pri | Status |
|---|---|---|---|
| LINK-1 | `waypoints://` opens a profile, car, meet, team, listing, post, team invite, or convoy invite. | P0 | Coded |
| LINK-2 | The same paths work as HTTPS universal links, so a shared link is tappable in Messages and opens the app. Without the app it opens a plain page saying what the link is and where to get Waypoints. | P0 | Partial: no host chosen yet (`LINK_HOST`, section 9.1 step 6) and `TEAMID` in the association file is a placeholder. |
| LINK-3 | Everything shareable shares the HTTPS link once LINK-2 is configured. | P0 | Partial: `Route.shareURL` gives the https form; Convoy, Garage, Feed, Teams, and Meets still build `waypoints://` strings themselves. |
| LINK-4 | A static site in `site/` holds the link landing page, the association file, the Terms, and the Privacy Policy. Plain HTML, no build step, free hosting (section 9.1). | P0 | Partial: not yet published to a host. |
| LINK-5 | Share cards. A meet shares as an image (title, time, place, a map snapshot) alongside its link. Builds and time slips have theirs (GAR-15, STR-5). | P1 | Partial: the meet card is coded; builds and time slips belong to GAR-15, STR-5. |

---

## 5. Requirements that cut across areas

### 5.1 Design (DES)

Plan section 9 is the law. These make it checkable.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| DES-1 | Feature code contains no literal colour, font size, radius, spacing, or duration. Only `DesignSystem` tokens. | P0 | Partial: one place sizes things outside the token scale (a rectangle in the Strip). |
| DES-2 | Features build screens only from `DesignSystem` components. None draws its own button, row, field, or sheet. | P0 | Coded |
| DES-3 | No pattern banned by plan 9.11 appears anywhere. | P0 | Coded |
| DES-4 | Every screen in plan section 10 has its loading, empty, error, and offline states, with the plan's copy. | P0 | Coded |
| DES-5 | Every control on every screen does something. A screen-by-screen walk finds no dead button, placeholder, or "coming soon". | P0 | Coded |
| DES-6 | Motion starts from what was touched. Haptics fire only on the user's own actions, as plan 9.6 lists. | P0 | Coded |
| DES-7 | Every screen has been captured and read against its plan entry and 9.11 by an agent, and the findings fixed (section 7.3). | P0 | Missing |
| DES-8 | Dark only. One accent, used once per screen as a filled control. | P0 | Coded |

### 5.2 Accessibility (A11Y)

| ID | Requirement | Pri | Status |
|---|---|---|---|
| A11Y-1 | Dynamic Type through AX5 without clipping primary text. | P0 | Coded |
| A11Y-2 | Every control and marker has a VoiceOver label that says what it is and its state. | P0 | Coded |
| A11Y-3 | Reduce Motion turns transitions into crossfades and stops loops. | P0 | Coded |
| A11Y-4 | Colour is never the only signal. Text contrast meets 4.5:1, glyphs 3:1. | P0 | Coded |
| A11Y-5 | Hit targets are at least 44 pt, markers included. | P0 | Coded |

### 5.3 Concurrency (CONC)

The engineering headline of the project. Plan 3.2, 7.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| CONC-1 | Swift 6 language mode with complete strict concurrency in every target, with no warnings. | P0 | Verified: `make build`, 2026-11-13. |
| CONC-2 | Shared mutable state lives in an actor or on the main actor. One `@unchecked Sendable` type, the audio render kernel. No `nonisolated(unsafe)`. | P0 | Verified: source search, 2026-11-13. |
| CONC-3 | Realtime data flows as `AsyncSequence`. The connection is one task group (receive, send, heartbeat) inside a reconnect loop with exponential backoff and full jitter, and it leaks no tasks across reconnects. | P0 | Coded |
| CONC-4 | The audio render block allocates nothing, takes no lock, and makes no runtime call. | P0 | Coded |
| CONC-5 | The gateway uses one reader and one writer goroutine per connection, shard goroutines that own their state without locks, bounded channels, and conflation. Only location may be dropped. | P0 | Coded |
| CONC-6 | A slow reader is closed without delaying anyone else. | P0 | Coded |
| CONC-7 | The gateway runs a 60-second smoke scenario under the race detector with no reports. | P0 | Coded |

### 5.4 Performance (PERF)

Targets are from plan 8.1 and are judged on the reference machine. What was measured, on what, is published; a missed target is stated with the reason.

| ID | Requirement | Pri | Status |
|---|---|---|---|
| PERF-1 | 50,000 idle connections per node under 2.5 GB; under 50 KB per connection. | P0 | Coded |
| PERF-2 | 5,000 publishers at 1 Hz with mean fan-out 20: p50 at most 60 ms, p99 at most 150 ms, p99.9 at most 250 ms with a 100 ms tick. | P0 | Coded |
| PERF-3 | Under 30 bytes per delivered update. | P0 | Partial: 27 to 28 bytes with the 100 ms tick, 33 in immediate mode (Benchmark I, local). |
| PERF-4 | With 5% of subscribers stalled, healthy subscribers' p99 moves under 10% and stalled ones are closed within 6 s. | P0 | Coded |
| PERF-5 | Two nodes over NATS add under 10 ms to p99 against one node at the same load. | P0 | Coded |
| PERF-6 | 10,000 connections that drop return within 15 s with no restart. | P0 | Coded |
| PERF-7 | The results, the raw data behind every number, and a short account of what limited it are in `docs/BENCHMARKS.md` and summarised in `README.md`. | P0 | Partial: Benchmark I only. |
| PERF-8 | The app is under 60 MB installed. | P0 | Coded |

### 5.5 Reliability (REL)

| ID | Requirement | Pri | Status |
|---|---|---|---|
| REL-1 | Denying any permission (location, notifications, camera, microphone, photos, calendar) never crashes and never dead-ends: the screen says what is off and how to turn it on. | P0 | Coded |
| REL-2 | Offline, the app opens, shows what it last had, and says so in one banner. | P0 | Coded |
| REL-3 | A failed submit keeps everything the user typed and says why under the button. | P0 | Coded |
| REL-4 | Losing and regaining the network recovers the realtime connection without user action. | P0 | Coded |
| REL-5 | A feature whose service is not configured (voice without LiveKit keys, push without an APNs key) hides or explains itself. It does not error. | P0 | Coded |

### 5.6 Security (SEC)

| ID | Requirement | Pri | Status |
|---|---|---|---|
| SEC-1 | Row-level security is on for every table, and `supabase/checks.sql` prints PASS for every access rule in plan section 5, including every table added since. | P0 | Coded |
| SEC-2 | The service-role key, the LiveKit secret, and the APNs key exist only on the gateway. No secret is committed. | P0 | Coded |
| SEC-3 | The gateway verifies Supabase tokens against the project's keys and fails closed. The token travels in the first frame, never in a URL. | P0 | Coded |
| SEC-4 | Users write storage only under their own prefix. Uploaded photos and videos carry no location metadata. | P0 | Coded |
| SEC-5 | Benchmark and development back doors (`-bench` tokens, `/dev` endpoints, debug launch arguments) cannot be enabled in a production build or environment. | P0 | Coded |

### 5.7 App Store compliance (CMP)

| ID | Requirement | Pri | Status |
|---|---|---|---|
| CMP-1 | A privacy manifest and purpose strings that match what the app does. | P0 | Coded |
| CMP-2 | Account deletion inside the app (ACC-10). | P0 | Coded |
| CMP-3 | For user content: terms accepted first, a filter, report, block, action within 24 hours, a published contact (SAFE). | P0 | Coded |
| CMP-4 | Review notes explain location use, the absence of speed display, and that racing is virtual. `docs/APP_STORE.md` holds them with the listing copy and the privacy-label answers. | P0 | Coded |
| CMP-5 | Terms of Service and a Privacy Policy at public URLs (LINK-4). | P0 | Partial: pages in `site/`, not yet published; S6 rows appear once `LINK_HOST` is set. |
| CMP-6 | An app icon, drawn by a script in the repository from the design tokens. | P0 | Coded |
| CMP-7 | App Store screenshots produced by the harness in section 7, from seed data with real model names. | P1 | New |

### 5.8 Observability, size, language (OBS, L10N)

| ID | Requirement | Pri | Status |
|---|---|---|---|
| OBS-1 | The gateway exposes connection, publish, delivery, drop, outbox, and flush metrics on a private port, with `pprof`. | P0 | Coded |
| OBS-2 | The client collects MetricKit diagnostics and can show the last payload on a debug screen. No third-party SDK. | P1 | Coded |
| L10N-1 | English only. Every string lives in a String Catalog in its module. | P1 | Missing |

---

## 6. What this document adds to the plan

Everything below passed both tests in section 2. Each reuses what is already built.

| Addition | Requirements | Pri | Why it earns its place | Built from |
|---|---|---|---|---|
| Catalog supplement and free-text at every step | GAR-2, GAR-3 | P0 | "Every car" fails today for a 1969 Camaro or an R34. | The catalog tool and the existing trim form. |
| Moderation that works with one reviewer | SAFE-6 to SAFE-8 | P0 | App Review expects violators to be removed; today there is no way to. | Two columns and four SQL functions. |
| Universal links and a static site | LINK-2 to LINK-4 | P0 | Invites cannot be tapped in Messages, and the store needs public Terms and Privacy pages. | Static HTML on free hosting. |
| Road privacy guard | ROAD-3 | P0 | A saved road must not point at someone's home. | Home zones already on the device. |
| Recurring meets | MEET-12 | P1 | Cars and Coffee is weekly. The plan promises recurring meets and has no field for them. | The gateway's existing sweep. |
| Roll out | MEET-13 | P1 | Joins Meets, Convoy, and Roads into the thing a cruise actually is. | Existing convoy endpoints. |
| Convoy voice | CNV-11 | P1 | The competitor has it; the plan had it only for teams. | The voice token endpoint and sheet. |
| Help requests | HELP-1 to HELP-7 | P1 | Nobody ships it, and it is the most car-community thing on the map. | Reports plumbing and per-user subjects. |
| Camera reports | RPT-9 | P1 | Expected by anyone coming from Waze. | Two enum values and two glyphs. |
| Activity | NTF-6, NTF-7 | P1 | Without it, likes and requests are invisible unless push works. | The triggers that already push. |
| Market categories and Wanted | MKT-7, MKT-8 | P1 | Two kinds is not a full market. | One column, one enum value. |
| Codes, cards, earned icons on profiles | SOC-9, GAR-15, LINK-5, ICN-7 | P1 | Meets are face to face, and a shared card is the only marketing there is. | Core Image, `ImageRenderer`, `MKMapSnapshotter`. |
| The ladder | STR-9 | P1 | Gives the Strip a reason to come back alone. | The existing house-car opponent. |
| Face blur, abuse limits | SPOT-6, SAFE-9 | P1 | Bystanders and spam. | Vision; a counting trigger. |
| Agent harness, MetricKit, String Catalogs, icon | Section 7, OBS-2, L10N-1, CMP-6 | P0 to P1 | The project cannot be finished or shipped without them. | Launch arguments and `simctl`. |
| Share ETA, people's choice, photo posts, service log, driven map, bench race, listing expiry | NAV-15, MEET-14, FEED-11, GAR-16, ROAD-5, STR-10, MKT-9 | P2 | Worth having; not worth delaying 1.0. | Existing modules. |

---

## 7. Verification without a test suite

There are no test targets. A requirement is Verified when an agent has run something and read the result. Wave 6 starts by building the tools that make that possible.

### 7.1 The harness (built by W6-A)

| Tool | What it does |
|---|---|
| `make dev` | Starts local Supabase, resets and seeds it, writes `server/.env` and `ios/App/Config.xcconfig` from `supabase status`, and runs the gateway. |
| `make check-db` | Runs `supabase/checks.sql`. Exits non-zero if any access rule prints FAIL. |
| `make check-rt` | Runs `server/cmd/rtdebug`: scripted clients, signed in as seed users, that assert the gateway's behaviour (precise, approximate, hidden, ghost, nearby anonymity, viewport swap, slow consumer, convoy) and print PASS or FAIL per scenario. |
| `-wp-preview` | Launch argument. Builds the environment from `PreviewEnvironment`: no backend, realistic seed data. |
| `-wp-login <handle>` | Launch argument. Signs in as a seed user with the development password. Works only in debug builds against a loopback Supabase URL. |
| `-wp-open <url>` | Launch argument. Opens a link after launch. Debug builds add `waypoints://debug/<screen>` paths so every screen and state in plan section 10 can be reached without tapping. |
| `make shot NAME=<n> ARGS="..."` | Boots a simulator, installs, launches with the arguments, waits for the screen to settle, and writes `.build/shots/<n>.png`. |
| `make drive ROUTE=<name>` | Feeds the simulator a moving location along a stored route and grants location permission, both through `simctl` *(verify the subcommands on the installed Xcode)*. |
| `-wp-smoke` | Launch argument. Calls every repository method once against the backend and prints PASS or FAIL per method to the console. |

Two simulators booted with different `-wp-login` handles cover every two-person flow.

### 7.2 Proving a requirement

Pick the cheapest proof that would actually fail if the requirement were broken:

1. **Build**: for rules the compiler enforces.
2. **Script**: `make check-db`, `make check-rt`, `-wp-smoke`, `curl` against the gateway, a benchmark run.
3. **Screenshot**: `make shot`, then read the image against the plan's entry for that screen.
4. **Device**: only for the list in section 9.3.

The commit that sets a status to Verified says which, for example `Verified: MEET-1, MEET-3 (shot e1-start, check-rt meets)`.

### 7.3 Reading a screenshot

For each capture, the agent checks, in order: the layout matches the plan's entry; every string matches the plan's copy; nothing from plan 9.11 is present; only tokens are visible (one accent fill, no stray colour); every control shown is wired; the state under test (empty, error, offline) is the one on screen. Findings are fixed in the same package or written into the requirement's row.

### 7.4 Done

A package is done when `make build` exits 0 with no warnings in the files it owns, its requirements are Verified or their rows say exactly what is left, the plan is updated where a contract changed, and it is committed to `main`.

---

## 8. Roadmap and work packages

### 8.1 Rules for every package

- Read section 0.2. Work inside "Owns".
- **Shared files.** `Backend`, `Core`, and migrations serve many features. A package may make the smallest fix it needs in a file it does not own when its acceptance depends on it: pull first, change only the lines needed, and add `Shared fix: <file>` to the commit message. New migrations are new files named `<UTC timestamp>_<package id>_<name>.sql`; an existing migration is never edited.
- **Contracts.** A change to plan 4.3, 5, or 6 is made in the plan in the same commit, under "Contract change:".
- Only packages marked alone may edit `Package.swift`, `AppShell`, `ios/App`, or the `Makefile`.
- A package that finds a gap outside its area writes it into that requirement's row and moves on.
- CONC-1 and CONC-2 are standing gates. Every package leaves them true.

### 8.2 Wave 6: it runs

End state: the whole app runs on the local stack, every screen has been seen, every P0 requirement that exists in code is Verified or has its gap written down.

**W6-A Local stack and harness** (alone, first)
- Covers: section 7.1, LINK-1, ACC-11, GAR-7.
- Owns: `Makefile`, `tools/dev/**`, `ios/App/**`, `Sources/AppShell/**`, `Sources/Core/Preview/**`, `server/cmd/rtdebug/**`, `supabase/seed.sql`, `supabase/config.toml`, `README.md`.
- Also: put the catalog snapshot into the app during the build (GAR-7): the `ios` target of the Makefile builds `catalog.sqlite.lzfse` with `tools/catalog` from its cache when it is missing and copies it to `ios/App/Resources/`, which stays untracked.
- Acceptance: on a clean clone with section 9.1 steps 1 and 2 done, `make dev` brings the stack up; `make shot NAME=map ARGS="-wp-login <seed handle>"` shows the live map with seed friends on it; `make shot NAME=g6 ARGS="-wp-preview -wp-open waypoints://debug/modsim"` works with no backend; `make check-db` and `make check-rt` run and print their results; the picker shows the real catalog, not the seed.

**W6-B Gateway and data layer** (alone, after A)
- Covers: PRV-1 to PRV-14, CONC-3, CONC-5 to CONC-7, SEC-1 to SEC-5, OBS-1, ACC-9, ACC-10, CMP-2, RPT-3 to RPT-6, CNV-9, CNV-10, NTF-2.
- Owns: `server/internal/**`, `Sources/Backend/**`, `Sources/RealtimeClient/**`, `Sources/LocationKit/**`, `Sources/GatewayAPI/**`, new migrations.
- Also: define `delete_account`; split `server/internal/api/register.go` into `reports.go` and `meets.go` so later packages can own one each.
- Acceptance: `make check-db` prints no FAIL; `make check-rt` passes every scenario, including the plan's W1-2 list; `-wp-smoke` prints no FAIL; the race-detector smoke run is clean; deleting an account removes the auth user and every row.

Then in parallel. Each package walks every requirement it covers with the harness, fixes what is wrong, closes the gaps named in its rows, and sets statuses. Each also proves DES-2 to DES-6, DES-8, A11Y, REL-3, and REL-5 for its own screens.

| Package | Covers | Owns |
|---|---|---|
| **W6-1 Accounts, settings, safety, notifications** | ACC, SET, SAFE-1 to SAFE-5, SAFE-10, SAFE-11, PRV-6, PRV-7, PRV-10, PRV-12, NTF-1, NTF-3 to NTF-5, REL-1 | `Sources/OnboardingFeature/**`, `Sources/SettingsFeature/**`, `Sources/SafetyKit/**`, `Sources/PushKitBridge/**` |
| **W6-2 Map and markers** | MAP, ICN-1 to ICN-6, REL-2, REL-4 | `Sources/MapFeature/**`, `Sources/ProgressFeature/**`, `Sources/DesignSystem/MapIcons/**` |
| **W6-3 Navigation and reports** | NAV-1 to NAV-14, RPT-1 to RPT-8 | `Sources/NavigationFeature/**`, `Sources/ReportsFeature/**` |
| **W6-4 Meets and convoys** | MEET-1 to MEET-11, CNV-1 to CNV-10 | `Sources/MeetsFeature/**`, `Sources/ConvoyFeature/**` |
| **W6-5 Garage and catalog** | SOC, GAR-1 to GAR-14 | `Sources/GarageFeature/**`, `Sources/VehicleCatalog/**`, `tools/catalog/**` |
| **W6-6 Simulator, sound, strip** | MOD, STR-1 to STR-8, CONC-4 | `Sources/PerformanceModel/**`, `Sources/EngineAudio/**`, `Sources/ModSimFeature/**`, `Sources/RaceFeature/**` |
| **W6-7 Teams, messages, voice** | TEAM, MSG, VOX | `Sources/TeamsFeature/**`, `Sources/MessagingFeature/**`, `Sources/VoiceFeature/**` |
| **W6-8 Feed and Showdown** | FEED-1 to FEED-10, SHOW | `Sources/FeedFeature/**`, `Sources/ShowdownFeature/**` |
| **W6-9 Market, spots, roads** | MKT-1 to MKT-6, SPOT-1 to SPOT-5, ROAD-1 to ROAD-4, PRV-15 | `Sources/MarketFeature/**`, `Sources/SpotsFeature/**`, `Sources/RoadsFeature/**` |

Notes that are easy to miss:

- **W6-5** carries the two data jobs. The supplement (GAR-2) is model names and year spans. The specs (GAR-8) are numbers, and every row needs a source URL the agent opened; a row without one is not added. Start with the model-generations listed in plan 11.1.
- **W6-6** writes `ReferenceCars.swift` and its debug screen (MOD-13) before touching the model, then adds the kits (MOD-2) under the same sourcing rule.
- **W6-7** cannot verify VOX until section 9.1 step 5 is done. Until then VOX stays Coded and REL-5 is what gets verified. The same holds for W6-1 and push delivery (NTF-2, NTF-3) until step 4.
- **W6-8** adds the weekly close (SHOW-7) as a scheduled Postgres function, and the For you ordering (FEED-2) as one RPC.
- **W6-2** judges the silhouettes (ICN-1) from a gallery screenshot at 28, 40, and 44 pt over a dark map, and redraws any that cannot be told apart.

**W6-INT** (alone): the two-simulator walk from the plan's W1-INT through every tab; DES-7 for every screen in plan section 10; fix seams; update the plan for the differences in section 3.3; refresh section 3 of this document.

### 8.3 Wave 7: version 1.0 complete

End state: every P0 and P1 requirement in section 4 is Verified. The section 5 requirements that need a host or an Apple account (PERF, CMP-1, CMP-4, CMP-7) close in wave 8.

| Package | Covers | Owns |
|---|---|---|
| **W7-1 Moderation and limits** | SAFE-6 to SAFE-9, CMP-3 | A migration, `supabase/moderation.sql`, `Sources/SafetyKit/**`, `server/internal/auth/**` |
| **W7-2 Activity** | NTF-6, NTF-7 | A migration, `Sources/PushKitBridge/**`, `server/internal/push/**`, one new `Backend` file. The bell on G1 is a shared fix in `GarageFeature`, shown only when the activity route has a handler. |
| **W7-3 Meets that repeat and roll out** | MEET-12, MEET-13, LINK-5 | A migration, `server/internal/api/meets.go`, `Sources/MeetsFeature/**` |
| **W7-4 Help and cameras** | HELP, RPT-9 | A migration, `proto/**` and generated types, `server/internal/api/reports.go`, `server/internal/help/**`, `Sources/ReportsFeature/**` |
| **W7-5 Convoy voice** | CNV-11 | `server/internal/voice/**`, `server/internal/convoy/**`, `Sources/VoiceFeature/**`, `Sources/ConvoyFeature/**` |
| **W7-6 Market** | MKT-7, MKT-8 | A migration, `Sources/MarketFeature/**` |
| **W7-7 The ladder** | STR-9 | A migration, `Sources/RaceFeature/**` |
| **W7-8 Codes, cards, profile icons** | SOC-9, ICN-7, GAR-15, SPOT-6 | `Sources/GarageFeature/**`, `Sources/TeamsFeature/**`, `Sources/SpotsFeature/**`, one new component in `Sources/DesignSystem/Components/` |

Then, each alone:

**W7-9 Links and site**
- Covers: LINK-2 to LINK-4, CMP-5.
- Owns: `site/**`, `ios/App/**` (entitlements), `Sources/AppShell/**`, `ios/project.yml`.
- Acceptance: the site serves the association file, the landing page, Terms, and Privacy from the host in section 9.1 step 6; a link pasted into the simulator's Messages opens the app at its target; every share sheet uses the HTTPS form. Until the host exists, the package ships everything but the hostname and leaves LINK-2 Partial.

**W7-10 Polish**
- Covers: L10N-1, OBS-2, CMP-6, DES-1, SET-3, A11Y, PERF-8.
- Owns: every module, for string extraction only; `ios/App/**`; `tools/icon/**`.
- Acceptance: every module has a String Catalog and no inline user-facing string; the icon is generated by a script and present at 1024 px; the accessibility walk (VoiceOver labels through each tab's main flow, AX5 captures of every root screen, Reduce Motion) has no open finding; installed size is measured and written into PERF-8.

**W7-INT** (alone): full regression of section 4 with the harness; refresh section 3; plan updated for every contract change in the wave.

### 8.4 Wave 8: ship

**W8-1 Deploy and benchmarks**
- Covers: PERF-1 to PERF-7.
- Owns: `deploy/**`, `bench/**`, `docs/BENCHMARKS.md`, `server/cmd/loadgen/**`.
- Needs: section 9.1 steps 3 and 7.
- Acceptance: the gateway runs on the host behind TLS with the hosted Supabase project; Benchmark II (two nodes, slow consumers, reconnect storm) and Benchmark III (the full matrix on the reference machines, or loopback and labelled so) are recorded with raw results; every missed target is stated with the profile that explains it; `README.md` carries the summary table.

**W8-2 Store**
- Covers: CMP-1, CMP-4, CMP-7.
- Owns: `docs/APP_STORE.md`, `ios/App/PrivacyInfo.xcprivacy`, `tools/screenshots/**`.
- Needs: section 9.1 step 4.
- Acceptance: `make archive` produces a Release build pointed at the hosted backend; the screenshots are generated; listing copy, review notes, privacy-label answers, and the age-rating answers are final.

**W8-INT** (alone): the owner's device check (section 9.3) with every finding fixed; tag `v1.0`.

### 8.5 Wave 9: version 1.1

Starts after 1.0 is on TestFlight. One package per row, in parallel, then W9-INT.

| Package | Covers | Owns |
|---|---|---|
| **W9-1 Share ETA** | NAV-15 | `Sources/NavigationFeature/**`, one gateway endpoint |
| **W9-2 People's choice** | MEET-14 | A migration, `Sources/MeetsFeature/**` |
| **W9-3 Photo posts** | FEED-11 | A migration, `Sources/FeedFeature/**` |
| **W9-4 Service log** | GAR-16 | A migration, `Sources/GarageFeature/**` |
| **W9-5 Driven map** | ROAD-5 | `Sources/RoadsFeature/**` |
| **W9-6 Bench race** | STR-10 | `Sources/RaceFeature/**` |
| **W9-7 Listing expiry** | MKT-9 | A migration, `Sources/MarketFeature/**` |

### 8.6 At a glance

| Wave | Packages | Result |
|---|---|---|
| 6 | A, then B, then 1 to 9, then INT | The app runs end to end locally. Every screen seen. Coded requirements proven or their gaps named. |
| 7 | 1 to 8, then 9, 10, INT | Version 1.0 feature-complete and verified. |
| 8 | 1, 2, INT | Deployed, benchmarked, on TestFlight, ready to submit. |
| 9 | 1 to 7, INT | Version 1.1. |

---

## 9. Owner's actions

Only these need a person. Nothing else in this document may wait on one.

### 9.1 Setup

| # | Action | Needed by | State on 2026-11-13 |
|---|---|---|---|
| 1 | `brew install supabase/tap/supabase nats-server`. An agent may run this if asked. | W6-A | Not done. Docker, XcodeGen, `protoc`, and Go are installed. |
| 2 | Keep Docker Desktop running while agents work; the local Supabase stack needs it. | W6-A | Running. |
| 3 | Create a hosted Supabase project (free). Put its URL and anon key in `ios/App/Config.xcconfig`, and its service-role key and database URL in `server/.env`. Enable email one-time codes. Confirm asymmetric JWT signing keys. | W8-1 | Not done. Waves 6 and 7 use the local stack. |
| 4 | Join the Apple Developer Program ($99 a year, the only cost). Register the bundle id `app.waypoints.ios` with Push Notifications, Sign in with Apple, and Associated Domains. Create an APNs key and put its ids in `server/.env`. Configure Sign in with Apple in Supabase. | W8-2, and to verify ACC-1 and NTF on a phone | Unknown. |
| 5 | Create a LiveKit Cloud project (free). Put its URL, key, and secret in `server/.env`. | Verifying VOX and CNV-11 | Not done. |
| 6 | A host name for links, Terms, and Privacy. Free: a GitHub Pages user site (`<user>.github.io`) serving `site/`. Or a domain. Tell the W7-9 agent which. | W7-9 | Not done. |
| 7 | A host for the gateway. Free: an Oracle Cloud Always Free VM *(verify availability)*, per `deploy/README.md`. Otherwise any free tier that allows WebSockets, accepting that it sleeps. | W8-1 | Not done. |
| 8 | A contact email that is really monitored. `docs/APP_STORE.md` names `support@waypoints.app`; confirm that address exists or replace it. | W7-9 | Unconfirmed. |
| 9 | Delete the old Render service, any Fly.io app, and the old Expo project. | Any time | Unknown. |
| 10 | App Store Connect: create the app record, upload the build from W8-2, paste the listing, answer the questionnaires from `docs/APP_STORE.md`, submit. | After W8-INT | Not started. |

### 9.2 Ongoing

Review `content_reports` within 24 hours of each report, using the functions from SAFE-8. This is the one recurring human job, and App Review expects it.

### 9.3 The device check

About twenty minutes on a real iPhone, once, before W8-INT closes. These are the things no simulator or script can judge:

1. Sign in with Apple completes.
2. A push arrives for each of the six kinds and opens the right screen.
3. Two phones talk in a voice channel; voice survives locking the phone and a navigation prompt.
4. Background sharing continues with the app closed and stops after 5 minutes parked.
5. The exhaust sounds like an engine of the right layout, changes in the right direction with each mod, and does not crackle or drop out.
6. Haptics feel right on the picker, the Showdown pick, and a Strip launch.
7. The VIN scanner reads a real VIN. A spot photo of a real car has its plate blurred.
8. Guidance on a real drive: voice timing, rerouting, the hazard strip.
9. The map holds 60 fps while friends move.
10. Nothing on any screen looks generated. The owner's eye is the last check of plan 9.11.

Findings go to W8-INT as a list.

---

## 10. Free-tier ceilings

| Service | Ceiling | What happens at it | Handling |
|---|---|---|---|
| Supabase storage | About 1 GB *(verify)* | Uploads fail. | Videos capped at 12 MB and 30 s; photos at 2048 px. Roughly 100 videos fit. FEED-11 eases it. Upload failure is a designed state (FEED-7). |
| Supabase project | Pauses after about a week idle *(verify)* | The app cannot sign in. | Any use keeps it awake. An idle project is resumed from the Supabase dashboard; `README.md` says so. |
| LiveKit | About 5,000 participant-minutes a month *(verify)* | Voice refuses to connect. | VOX-5 has the state. |
| Gateway host | One small VM | Fewer connections than the benchmark machine. | Irrelevant at real user counts. |
| APNs, MapKit, vPIC, EPA data | Free | | vPIC is fetched at 2 requests a second and cached by the catalog tool, never by the app. |

---

## 11. Risks

| Risk | Likelihood | What it would cost | Handling |
|---|---|---|---|
| Twenty thousand lines that have never run hide more breakage than expected. | High | Wave 6 grows. | Wave 6 exists for this. W6-A and W6-B go first so every later package has tools and a working data layer. |
| Specs or kit figures written from memory are wrong. | High without the rule | The simulator's one promise, honesty, is broken. | A source URL on every row, opened by the agent (section 2.2). MOD-13 catches model error. |
| Generated silhouettes look like the same lozenge. | Medium | The icon set, a headline ask, falls flat. | ICN-1 is judged from a screenshot in W6-2 and failing icons are redrawn. The owner's device check is the last word. |
| App Review rejects for location, user content, or racing. | Medium | A resubmission cycle. | Sections 2.1, 4.23, 5.7; review notes already drafted; STR-6 guardrails are mandatory. |
| The synthesized exhaust sounds synthetic. | Medium | Disappointment with a headline feature. | It is labelled "Synthesized sound" and promises direction of change, not a recording (plan 11.3). Device check item 5. |
| MapKit cannot be steered around hazards. | Certain | Low-car routing is scoring, not avoidance. | Said plainly in the interface (NAV-3). |
| A free tier is withdrawn or shrinks. | Low to medium | One service must move. | Each is behind one module or one gateway package. |
| Scope creep from this document's own additions. | Medium | 1.0 slips. | P1 is capped at what wave 7 lists. Anything else new is P2 or backlog. |

---

## 12. Backlog, and what never ships

**Not scheduled.** Each needs a reason and a row in section 4 before it starts.

- CarPlay (needs an entitlement Apple grants on request), Live Activities and widgets, Apple Watch, iPad layouts, Android, a web client.
- Passed-you digest (plan 2.4).
- Message reactions, threads, typing indicators.
- Meet weather (WeatherKit), tire-size and gearing calculators, fuel log.
- A light theme, more languages.
- Team-against-team rankings.
- An admin app for moderation (the SQL functions are enough until volume says otherwise).

**Never.** These contradict section 2.1.

- Showing anyone's speed to anyone else. Points, ranks, or icons for speed or distance.
- Real-world racing in any form: challenges with a place or time, roll racing, lap or sprint timing by GPS, leaderboards of real times.
- Checkpoint reports.
- Subscriptions, currency, boosts, paid icons, prize wheels, promoted listings, payments in the market.
- Third-party analytics, advertising, or tracking.
- Server-side location history.
- Manufacturer logos.

**Left out for engineering reasons.** Plan section 15 stands: no route generation by twistiness, no true hazard-avoiding routing, no live multiplayer racing, no recorded engine samples, no video transcoding, no end-to-end encrypted messages, no Redis, Kafka, or Kubernetes.

---

## 13. Change log

| Date | Change |
|---|---|
| 2026-11-13 | First version. Written from the owner's original brief, `docs/PLAN.md`, and an audit of commit `80823e1`. Adds the requirements marked New, the harness in section 7, and waves 6 to 9. Sets the order of authority in section 0.1. |
