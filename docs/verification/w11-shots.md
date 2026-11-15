# W11 verification pass — screenshots and debug screens

Date: 2026-11-15. Harness: existing Debug build in `.build/DerivedData` (no `make build`
run, per instructions), local Supabase stack already up, gateway not running (all captures
use `-wp-preview`, which needs no backend). Captures reviewed via macOS Vision OCR of every
PNG (no visual eyeballing available); layout judgement is from text bounding boxes, so
"clipped" flags are suspects, not certainties.

## Captures reviewed

App Store set (`.build/screenshots/`, `make screenshots` equivalent — `tools/screenshots/shots.sh`
was bypassed because it rebuilds; same `waypoints://debug/<screen>` launches on the same two
simulators, status bar pinned to 9:41 on both):

- `6.9/01-map` `02-meet` `03-route` `04-mod` `05-garage` `06-showdown` `07-team` `08-market` — all 8 OK after reshoots.
- `6.5/01-map` `02-meet` `03-route` `04-mod` `05-garage` `06-showdown` `07-team` `08-market` — 6 OK; `01-map` and `03-route` have issues below.

New W10 debug screens (`.build/shots/`, `-wp-preview -wp-open waypoints://debug/<name>`):

- `w11-car-of-week.png` — weekly board: car, est. ¼ mile, THIS WEEK runs (You 12.800 s), "Run it". OK.
- `w11-stops.png` — "Add a stop" sheet: Fuel / EV charging / Food, Wawa +2 min, Sunoco +4 min, Exxon +7 min. OK.
- `w11c-meet-capacity.png` — E2 with "4 of 4 cars", "Waitlist · 3", "You're on the waitlist, 2nd", "WHO'S GOING • 4". OK (MEET-15 visible).
- `w11-convoy-regroup.png` — map + Regroup sheet: place search, "Regroup there", "Regroup here". OK.
- `w11b-gearing.png` — "Gearing and tires": stock tire/final-drive inputs, SPEED AT REDLINE gears 1–6. OK.
- `w11c-modsim-builds.png` — G6 with Street vs Track day overlaid: EST HP 470/504, deltas +10/+44, 0-60 and ¼-mile side by side. OK (MOD-15).
- `w11c-standings.png` — team standings: "Showdown votes won by members' cars since Monday", Jersey Low Club 29, South Jersey Subies 24. OK.
- `w11-loop.png` — loop detail: "Pine Barrens loop", 28.0 mi, 3 roads, Drive it / Send to convoy / Share loop / Edit / Delete loop. OK.
- `w11-loop-edit.png` — editor: name field, ordered roads, TOTAL LENGTH, Save loop. OK.
- `w11-strip.png` / `w11-slip.png` — both resolve to the Strip lobby (`slip` shares the `race` route). Shows Build picker row ("Current mods"), CAR OF THE WEEK row (2019 Mustang GT, 12.800 s), OPPONENT, LADDER. See notes below.

Spanish pass (`-AppleLanguages (es)`, language picker equivalent for launch args):

- `w11-es-settings.png` — fully translated: Atrás, Ajustes, IDIOMA DE LA APP, Idioma → Sistema, Privacidad y ubicación, Notificaciones, Personas bloqueadas, Cuenta, Acerca de, Galería de diseño; tab bar Mapa/Novedades/Mercado/Equipos/Garaje. OK.
- `w11-es-map.png` — "¿A dónde?", tab bar translated; "4 friends out" stayed English (see issue L10N-A).
- `w11-es-meet.png`, `w11-es-meet-capacity.png` — mostly translated (En directo, Organizado por, Hoy 2:29 a.m., Indicaciones, Entrada/Aparcamiento, Estás en la lista de espera, 2°., Añade lo que sepas, Voy); "Maybe"/"Can't" and all integer-interpolated strings stayed English (issues L10N-A/B).

Superseded/failed first-pass captures kept for reference: `dbg-*.png` (home screen / black —
cold-launch under load), `w11-gearing.png`, `w11-loop.png`, `w11b-*.png` blanks where noted;
final good files are the `w11*`/`w11b*`/`w11c*` names above.

## Issues found

### L10N-A — every integer-interpolated string fails to translate (systemic)

`Text("\(int) …")` lookups never match the catalogs. The module catalogs (and the app
union catalog) only contain `%@` keys because `tools/l10n/extract.py` `key_of()` rewrites
every interpolation to `%@`, but at runtime SwiftUI generates `%lld` for `Int`
interpolations, so the lookup misses and the literal English pattern is shown.

Evidence (Spanish captures, `AppleLanguages (es)`):

- `MapFeature/MapScreen.swift:329` `Text("\(n) friends out")` → "4 friends out" on `w11-es-map.png` despite catalog `"%@ friends out" → "%@ amigos circulando"`.
- `MeetsFeature/MeetsFeature.swift:540` `Text("Who's going · \(count)")` → "WHO'S GOING • 4" on `w11-es-meet-capacity.png` despite `"Who's going · %@" → "Quién va · %@"`.
- `MeetsFeature/MeetsFeature.swift:523-525` `Text("\(count) of \(cap) cars")` / `Text("Waitlist · \(waiting.count)")` → "4 of 4 cars Waitlist · 3" despite `"%@ of %@ cars" → "%@ de %@ coches"` and `"Waitlist · %@" → "Lista de espera · %@"`.
- Control: `Text("You're on the waitlist, \(MeetFormat.ordinal(…))")` (String interpolation → `%@`) DID translate: "Estás en la lista de espera, 2°."

Same pattern is used for counts app-wide (`"\(s.memberUIDs.count) drivers"` ConvoyFeature.swift:300,
`"\(count) drivers"` DesignSystem/MapIcons/Markers.swift:267, `"\(r.responderCount) coming"` ReportsFeature/Help.swift:93, etc.), so this likely affects every number-bearing string in Spanish. Fix is not one line: either emit `%lld` keys for Int interpolations (extract.py + catalogs) or route counts through `String(localized:)`/format helpers. Needs a decision; reported, not fixed.

### L10N-B — "Maybe" and "Can't" have no catalog entries at all

`MeetsFeature/MeetsFeature.swift:511` passes `[(0, "Going"), (1, "Maybe"), (2, "Can't")]` as
plain string literals to the RSVP `SegmentedSwitch`; `tools/l10n/extract.py` does not
extract tuple-element literals, so `MeetsFeature/Resources/Localizable.xcstrings` has no
"Maybe"/"Can't" keys ("Going" → "Voy" works because that key exists). Visible on
`w11-es-meet.png` / `w11-es-meet-capacity.png`: "Voy / Maybe / Can't". Small fix (mark the
tuples `LocalizedStringKey` or extract them + add es translations) but touches copy;
reported, not fixed.

### STORE-1 — `6.5/01-map` opens on a regional view, `6.9/01-map` opens tight on Cherry Hill

Four attempts on iPhone 11 Pro Max all show the same wide fit (Pennsauken → Gibbsboro,
Delaware River labels) with no friend names or meet pin visible, while iPhone 16 Pro Max
shows the intended Cherry Hill close-up with "Jae Park", "Devon Price", "Rosa Delgado" and
the "4 friends out" pill. The map camera is not deterministic across devices/timing —
likely fit-to-content vs user-location depending on when markers load. For the App Store
set the 6.5 map is weaker and inconsistent with 6.9. Needs investigation (camera fit logic
in MapFeature), not fixed.

### STORE-2 — `6.5/03-route` shows the destination card without route details

Persistent across three attempts (WAIT 40–60 s): bottom card reads "Haddonfield train
station lot" with the car label, but no "10 min / 4 mi", no alternates, no "Go" button —
the 6.9 capture of the same screen is complete. Possibly the MKDirections result or sheet
detent differs on the smaller screen, or it needed longer than 60 s. Reported.

### STORE-3 — feed Showdown segment / `waypoints://debug/showdown` flakiness

`06-showdown` captures were blank or showed the feed tab on first attempts; the final
6.9 capture correctly shows ShowdownView (Street/Built/Show/Classic chips, MX-5 vs WRX
pair, Skip). One early 6.5 attempt showed the Feed tab with a "Couldn't play this. /
Try again" video error card — preview posts are all photo posts (`videoPath: nil`,
PreviewSeed.swift:299-308), so that error card should not be reachable in preview; it may
have been a transient capture of a different state. Flagging in case it reproduces.

### MINOR suspects (verify on device)

- `6.9/02-meet`: "Add what you know" sits at y≈0.96, essentially on the home-indicator
  edge of the medium-detent sheet — possible slight clipping.
- `w11b-gearing`: "Gear 6 … 178 mph" row ends at y≈0.975 — bottom of the scroll content may
  be under the home indicator (scrollable, so cosmetic at worst).
- `w11c-modsim-builds`: last "Track day" build row clipped at the bottom edge (list is
  scrollable).
- `w11-strip`: heavy content; the area just above the tab bar OCRs as garble ("Dant he" /
  "RAND") — almost certainly mid-scroll ladder rows, but worth one look on device.
- Meet times read "Today 2:40 AM" / "Happening now" — correct for the seed
  (`hours(-0.5)` start, PreviewSeed.swift:148-150) but means the meet screenshot only
  looks right at night; not a bug.

## Strip / time slip check (task item 3)

- Saved-build picker: PRESENT. `w11-strip.png` shows the "Build / Current mods" row in the
  lobby (`RaceFeature.swift:192-206` `buildMenu`), and preview seeds two builds on the
  Mustang (`Core/Preview/PreviewStore+W10SavedBuilds.swift`). The menu contents
  (Street / Track day) can't be verified without a tap.
- "Car of the week" slip line: code exists (`RaceFeature.swift:650`, `weekly` flag set only
  by the CarOfWeek "Run it" flow, `RaceFeature.swift:436-446`). `waypoints://debug/slip`
  resolves to the same lobby route as `strip`, and completing a run needs interaction, so
  the slip itself could not be captured headless. Needs a manual/device check (or a debug
  deep link to `TimeSlip`).

## PRD/code discrepancy (not fixed — docs are off-limits)

PRD MOD-15 row says "Partial … Left: the Strip does not yet offer a saved build", but the
Strip lobby does offer it (`buildMenu`, verified in `w11-strip.png`). The PRD row looks
stale; owner should update it.

## Harness notes for next time

- Under this machine's load (load avg >10, disk at 100%), cold launches took 60 s+ and the
  default `WAIT=6` produced black/home-screen captures. `WAIT=45–60` was needed; several
  screens also failed intermittently (deep link fired before `waitUntilSignedIn` + 300 ms
  elapsed, or sheet presented after the shot). A `WAIT` floor or a "wait for view" signal
  in `shot.sh` would make `make shot` reliable on a loaded machine.
- Disk was at 100% (176 MiB free) during the pass; `simctl screenshot` failed outright for
  two captures and Vision OCR errored transiently. Free space before the next run.
- The gateway was not running; nothing here exercised `-wp-login`/live backend paths.

## Still needs a physical device / manual pass

- TimeSlip "Car of the week" line (needs a completed weekly run).
- Build picker menu contents on the Strip; saved-build run path end to end.
- Real MapKit route search (`debug/stops` used preview results; PRD NAV-16 already notes the live search is unrun).
- VoiceOver/Dynamic Type/Reduce Motion passes (PLAN 9.12) — not covered by screenshots.
- Whether the `%lld`/`%@` interpolation bug also affects String interpolations in all
  modules (spot-checked: String interpolation translated correctly).
