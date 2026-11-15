# Client hardening results

Scope: items 2, 12, 13, 14–16, 17, 18, 19, and the client half of 20. Client files were edited; `features/` and `supabase/` were read-only (gaps reported, not fixed).

## 2. Secrets in tree and git history

Scanned: `git log --all -p -G` over all 261 commits for `service_role`, `sb_secret_`, `sk_live`, `BEGIN ... PRIVATE KEY`, `eyJ…` JWTs, `LIVEKIT_API_SECRET`, `APNS_`, `SUPABASE_JWT_SECRET`, `sb_publishable_`, `ghp_`, `AKIA`, `xox`, `AIza`, password/secret/key/token assignments; `git log --all --name-only` for `.env`, `*.p8`, `*.p12`, `*.pem`, `*.key`, `*.mobileprovision`, keystores; plus `git grep` of the worktree and reads of every `.env.example`/`eas.json`/`app.config.ts` revision in history.

Hits, all benign:

- `service_role` — only SQL `grant … to service_role` / `has_function_privilege` checks in `supabase/migrations/*` and `supabase/checks.sql`, and prose warnings in old `docs/MANUAL_ACTIONS.md`. Role name, not a key.
- `LIVEKIT_API_SECRET`, `APNS_*`, `SUPABASE_JWT_SECRET`, `SUPABASE_SERVICE_ROLE_KEY` — env-var names and placeholders (`your-service-role-key`, `legacy-jwt-secret`) in `server/README.md`, `server/internal/app/config.go`, `.env.example`, `deploy/`, and deleted pre-rewrite docs. No values.
- `waypoints-dev` — the local seed password, in `supabase/seed.sql`, `tools/dev/dev.sh`, `README.md`, and `ios/App/LaunchActions.swift`. Local-dev default; the Supabase CLI local stack only.
- `bench-secret`, `rtdebug-secret`, `dev-internal-secret` — bench/dev defaults in `bench/*.sh`, `tools/dev/*`. Local only; `WAYPOINTS_ENV=bench` gates them.
- `apps/mobile/eas.json` (deleted Expo app, history only) — `EXPO_PUBLIC_API_URL` hosts and empty `GOOGLE_MAPS_API_KEY`/`appleId`. Placeholders.
- Zero `eyJ…` JWTs, zero private-key blocks, zero real project URLs (`*.supabase.co` never appears in history).

Working tree: `git status --ignored` shows only `ios/App/Config.xcconfig` ignored (contains only `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`GATEWAY_URL`/`LINK_HOST` per `Config.example.xcconfig`), plus build caches. `deploy/` reads env from `server/.env` at runtime — nothing committed.

Bundle config: `Info.plist` carries `WPSupabaseURL`/`WPSupabaseAnonKey`/`WPGatewayURL`/`WPLinkHost` from xcconfig — URL + anon key only, as required. `Core/AppConfig.local` defaults to loopback with an empty anon key.

Dev-login gating: `-wp-login`/`-wp-smoke`/`-wp-open` handling in `LaunchActions.run` was partially ungated — the `-wp-open` block ran in Release. **Fixed**: all `-wp-*` effects are now inside `#if DEBUG` (`ios/App/LaunchActions.swift:59-80`); `devPassword` and `seedEmails` are `#if DEBUG` (`LaunchActions.swift:37-57`) so the dev password is no longer compiled into Release. `-wp-login` additionally refuses non-loopback Supabase hosts (`LaunchActions.swift:88-92`) and `debugSignIn` is `#if DEBUG` in both `LiveAuth.swift:129-139` and `Backend.swift:64-71`. `-wp-preview` was already DEBUG-only (`CompositionRoot.swift:17-24`), so Release cannot start in preview mode. `SmokeRunner.swift` is entirely `#if DEBUG`.

## 12. Session storage and logging

- supabase-swift 2.55.6 (`Package.resolved`), constructed in `Backend/Support/BackendContext.swift:13-20` with no `auth.storage` override → `AuthClient.Configuration.defaultLocalStorage` = `KeychainLocalStorage` (verified in `.build/DerivedData/SourcePackages/checkouts/supabase-swift/Sources/Auth/Storage/AuthLocalStorage.swift:44`). Keychain items use `kSecAttrAccessibleAfterFirstUnlock` (`…/Auth/Internal/Keychain.swift:86`) — correct for background location. Not UserDefaults. OK.
- Logging: `print`/`debugPrint`/`os_log`/`Logger` across all `Sources/` appear only in `AppShell/DebugLinks.swift` (DEBUG) and `ios/App/{LaunchActions,SmokeRunner}.swift` (DEBUG-gated). No token, email, or coordinate is logged in release paths. MetricKit payloads stay on device (OBS-2). OK.
- `DeviceTokenStore` keeps the APNs token in `UserDefaults` (`LiveAuth.swift:227-235`) — a push token, not a credential; covered by CA92.1.

## 13. UGC report/block (SAFE-1) — read-only findings

- Report sheet exists (`SafetyKit/SafetyViews.swift`, route `.reportContent` in `SettingsFeature.swift:17-34`) and is wired for: user, car, post, comment, message, listing, meet, map report, road, loop, help request (call sites in Feed/Garage/Market/Meets/Messaging/Reports/Roads features).
- **Gap:** `SpotsFeature` has no Report or Block UI at all — spots are not reportable despite SAFE-1 listing "spot". `TeamsFeature` has Block on members but no Report for a team. PRD SAFE-1 already says Partial (convoy member rows, voice participants also lack report). Reported, not fixed (outside my files).
- Blocks in RLS: `is_blocked_pair` is used in ~12 policies (messages, friendships, posts, follows, feed RPCs). **Gap:** `spots_read` (`20261113100100_w7-1_moderation.sql:270-273`) checks only `content_visible` — a blocked user's spots remain visible to the blocker; `teams_read` and `venue_notes_read` likewise lack `is_blocked_pair`. Reported for the supabase owner.
- Text filter: client-side `WordList` in `SafetyKit.swift` (13 slurs/threats) run via `safety.check` only on handle+name (Onboarding), post/comment text (Feed), messages (Messaging), listing title+description (Market). **Gap:** meet titles/notes, team names, road names, report notes, car names, spot captions, profile bio are not filtered, and the filter is client-only (a modified client bypasses it; no server-side CHECK/trigger found in migrations). SAFE-4 marked Coded; evidence supports Partial.
- Moderation functions: `moderation_hide/restore/suspend/unsuspend` exist in `supabase/migrations/20261113100100_w7-1_moderation.sql:439-520`, executable only by service role/postgres; runbook in `supabase/moderation.sql`. OK.
- `docs/APP_STORE.md` review notes state reports are reviewed within 24 h and give support@waypoints.app. OK.

## 14–16. Placeholders, dead UI, Info.plist, APP_STORE.md

- TODO/FIXME/lorem/"Coming soon": none in Sources (only design-system "placeholder" skeleton views, which are real UI). Sample names only inside `Core/Preview` and the DEBUG-gated seed emails. No empty-action buttons outside `#Preview`s and the design gallery.
- Debug UI in Release: design-gallery row, MetricKit row, "Reference cars" row are `#if DEBUG` (`SettingsFeature.swift:90-93`, `ModSimFeature.swift:325-331`, `SettingsFeature.swift:619-656`). Feature `registerDebugScreen` calls in Teams/Showdown/Roads/Navigation/Meets/Feed/Garage/Convoy are **not** individually gated, but are now unreachable in Release: `DebugLinks` is `#if DEBUG` file-wide and the sheet host in `AppShellView` is now `#if DEBUG` (fixed). `AppRouter.debugScreen`/`PresentedDebugScreen` remain compiled but unsettable in Release — harmless.
- Release launch args: fixed as in item 2 — no `-wp-*` argument has any effect in Release.
- Info.plist: every usage description is specific (location when-in-use/always, camera, mic, photo read/add, write-only calendar). `UIBackgroundModes` = location, audio, remote-notification — all used (nav/convoy voice/push). `ITSAppUsesNonExemptEncryption` = false. `UILaunchScreen` present, iPhone-only (`TARGETED_DEVICE_FAMILY: "1"`), portrait+landscape orientations sane, `waypoints` URL scheme correct.
- **Entitlements gap (fixed):** `Waypoints.entitlements` lacked `com.apple.developer.applesignin` (Sign in with Apple would fail with ASAuthorizationError 1000) and `aps-environment` (remote-notification registration would fail). Added `applesignin=Default` + `aps-environment=development` to `Waypoints.entitlements` and created `Waypoints.Release.entitlements` with `aps-environment=production`; `project.yml` now selects per configuration.
- APP_STORE.md: added demo-account sign-in steps (email OTP via webmail login), expanded the account-deletion note, added a pre-submission checklist mapping 1.2 / 2.1 / 4.2 / 4.8 / 5.1.1(v) / 5.1.2, and documented the Release entitlements. `<LINK_HOST>` and mailbox password remain owner placeholders (PRD 9.1).

## 17. Account deletion

Trace: Settings → Account → `env.auth.deleteAccount()` (`SettingsFeature.swift:513-526`) → `LiveAuth.deleteAccount` (`LiveAuth.swift:172-191`): removes storage objects under `<uid>/` in every media bucket, calls `delete_account` RPC (`supabase/migrations/20261113100000_w7-1_delete_account.sql` — `delete from auth.users`), clears the APNs token, signs out locally. `profiles.user_id` and 46 other FKs cascade `on delete cascade`, so rows go with the auth user. Gateway re-checks tokens, so the deleted user's JWT dies at expiry.

- **Fixed:** storage removal was best-effort (`try?` on list and remove; a failed list silently skipped the bucket, orphaning public files). Now `list`/`remove` throw via `ctx.run`, folder pseudo-entries (`id == nil`) are skipped, and any failure aborts deletion so the user can retry (`LiveAuth.swift:172-186`).
- **Update — Apple token revocation now implemented (server + client):** `deleteAccount` requests a fresh `ASAuthorizationAppleIDProvider` code for Apple-linked accounts and POSTs it to `POST /v1/apple/revoke` (`server/internal/api/apple.go`), which exchanges it and calls Apple's `/auth/revoke`; unconfigured env → 503, revocation failure never blocks deletion. Remaining owner step: create the SIWA `.p8` key and set `WAYPOINTS_APPLE_CLIENT_ID/TEAM_ID/KEY_ID/PRIVATE_KEY` on the gateway (PRD 9.1). Device test still pending.

## 18. Sign in with Apple

- Nonce: `SignInView` generates 32 random bytes hex (`OnboardingFeature.swift:193-198`), sends SHA-256 to Apple (`request.nonce`), passes the raw nonce to `signInWithApple` → Supabase verifies against the token's nonce claim. Correct.
- Error paths: cancel is ignored; other `ASAuthorizationError`s and backend errors map to user-facing copy (`show(_:)`); missing identity token handled. Email-code flow is the alternative (`sendEmailCode`/`verifyEmailCode`, 6-digit, resend throttle). Suspension shows the contact message.
- Name: only `.email` scope is requested; Apple returns the name only on first-ever authorization and the app collects display name + birth year itself at O2 — consistent with Apple guidance (name is not required from the credential).
- Entitlement fixed (item 16) — without it the flow could never succeed.

## 19. PrivacyInfo.xcprivacy

Required-reason APIs actually used by app code (grep over all Sources): `UserDefaults` (settings, convoy id, ladder, recents, APNs token, suspension flag) → CA92.1 declared; `FileManager.attributesOfItem` file size in `FeedFeature.swift:871` → C617.1 declared. No `systemUptime`/`mach_absolute_time`/`ProcessInfo.uptime`/disk-space/active-keyboard APIs. `NSPrivacyTracking` false; 10 collected data types all Linked, AppFunctionality-only, matching the schema (email, name, user id, device id=APNs token, precise location for help/road reports, coarse cell, photos/videos, messages, other UGC, birth year as OtherDataTypes).

Dependencies (checkouts under `.build/DerivedData/SourcePackages/checkouts`): LiveKit `client-sdk-swift`, `livekit-ffi-xcframework`, `webrtc-xcframework`, `swift-protobuf`, `swift-crypto` ship their own `PrivacyInfo.xcprivacy`. **supabase-swift 2.55.6 ships none**; its only required-reason-looking call is `attributesOfItem` in `Storage/MultipartFormData.swift` (SDK multipart upload path — the app uploads via raw `URLSession` in `LiveMedia.swift`, so it is never exercised). Not added to our manifest (third-party code, unused path); noted for the record. Manifest needed no changes.

## 20 (client). MetricKit and offline

- MetricKit: `ios/App/MetricsCollector.swift` subscribes via `MXMetricManager`, writes last diagnostic/metric payloads to Application Support; debug-only viewer in Settings (`MetricKitPayloadView`). Payloads never leave the device. OK.
- Offline: `RealtimeClient` has `NWPathMonitor` + `ConnectionState` stream with reconnect backoff; per-screen offline/error states exist (Feed `connectionBanner`, Messaging offline composer lock, Garage/Profile error states, sign-in offline copy). **Gap:** there is no single app-wide offline banner — only screens that opted in show it; screens without explicit handling rely on `WaypointsError.offline` mapping. Reported; other agents covered most screens.

## Files changed

- `ios/App/LaunchActions.swift` — dev password/seed emails and all `-wp-*` effects `#if DEBUG`.
- `ios/App/Waypoints.entitlements` — added `applesignin`, `aps-environment=development`.
- `ios/App/Waypoints.Release.entitlements` — new; `aps-environment=production`.
- `ios/project.yml` — per-config `CODE_SIGN_ENTITLEMENTS`.
- `ios/Packages/WaypointsKit/Sources/Backend/LiveAuth.swift` — strict, mapped storage removal in `deleteAccount`.
- `ios/Packages/WaypointsKit/Sources/AppShell/AppShellView.swift` — debug sheet host `#if DEBUG`.
- `docs/APP_STORE.md` — demo steps, deletion note, pre-submission checklist, Release entitlements note.

## For the parent / owner

- Run `make generate && make build` once (xcodegen must regenerate the project for the new entitlements configs; I did not build per instructions).
- Register `app.waypoints.ios` with Sign in with Apple + Push + Associated Domains (PRD 9.1 step 4) — now actually required by the entitlements.
- Apple token revocation on deletion needs a gateway endpoint + client re-auth (item 17); server-side work for another agent.
- Report/block gaps for the features/supabase owners: ~~spot report UI, team report, `is_blocked_pair` missing from `spots_read`/`teams_read`/`venue_notes_read`~~ — resolved in W11-H-6 (spot context-menu report, team/member report UI, block-aware read policies, word filter on team surfaces). Still open: text filter coverage on meet/road/report-note/car/bio fields (client-only `WordList`; a modified client bypasses it — needs a server-side pipeline to fully close SAFE-4).
- `supabase-swift` ships no privacy manifest (unused `attributesOfItem` path only).
