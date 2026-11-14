# App Store listing and review notes

Final copy for App Store Connect (PRD CMP-1, CMP-4, CMP-7; owner's action PRD 9.1 step 10). `<LINK_HOST>` is the value of `LINK_HOST` in `ios/App/Config.xcconfig`, the host that serves `site/`. Replace it before pasting.

## Listing

**Name:** Waypoints

**Subtitle** (30 of 30): Car meets, friends, and builds

**Category:** Social Networking (secondary: Navigation)

**Promotional text** (170 max):

See who's out, drop a meet in seconds, and drive in a convoy with voice. Lowered? Routes are scored for bumps and steep entrances.

**Description**

See who's out. Find the meet. Show the build.

Waypoints is a live map for car people. Your friends show up where they are; everyone else sees nothing unless you say so.

THE MAP
- Friends precise, teams approximate, drivers nearby hidden. You choose, per group. Ghost mode hides you from everyone. Home zones keep your house off the map.
- Report speed bumps, steep entrances, potholes, closures, hazards, speed cameras, and E85. Others confirm with "Still there" or "Gone".
- Routes are scored for a lowered car: how many bumps and steep entrances lie ahead, before you leave.
- Stuck? "Ask for a hand" shows your exact spot to your friends and teammates, and anyone can tap "On my way". It ends when you say you're good.

MEETS
- Start a meet in under 20 seconds: a pin, a title, a time. Meet, cruise, hangout, track day, or show.
- RSVP with the car you're bringing. Who's going shows cars, not faces.
- Recurring meets weekly, every two weeks, or monthly.
- Venue notes: entrance, lot size, lighting.
- Roll out: at start time a cruise turns into a convoy with its route, and everyone going is invited.

CONVOYS
- A shared route, the group in road order with gaps in time, and a regroup point when the group splits.
- Every convoy has voice. Join muted, tap to talk.

TEAMS AND MESSAGES
- Your club gets text channels, voice channels, roles, and team-only meets.
- Direct and group messages with photos.

GARAGE
- Add your real car from a catalog of thousands of models, or scan the VIN.
- Log the build: every mod, with dates and photos.
- The mod simulator: see what an intake, a tune, or a turbo does to power and the quarter mile, and hear the exhaust change. Every figure is an estimate with a range.
- Spot cars on the street. Plates and faces are blurred on your phone before upload.
- Save and rate your favourite roads.

SHOWDOWN AND THE STRIP
- Showdown: two builds, one vote. Rankings are votes, nothing else.
- The Strip: a virtual drag strip. Your garage car, your mods, your reaction time. Race your best run, a friend's run, or climb the ladder of ten house cars.

FEED AND MARKET
- Short videos from people you follow and from your region.
- Buy and sell parts and cars, or post what you're looking for. Parts filter to what fits your car. No fees, no checkout: meet in a public place.

ACTIVITY
- One list of what happened to you: requests, likes, comments, RSVPs, and meet changes. One notification per event, never a marketing push.

Nothing is for sale. Nobody ever sees your speed. For drivers 17 and older.

Terms: https://<LINK_HOST>/terms

**Keywords** (96 of 100): car meet,car club,cars and coffee,convoy,garage,mods,lowered,car spotting,cruise,drag,jdm,stance

**Support URL:** https://<LINK_HOST>/ (the footer links support@waypoints.app)
**Marketing URL:** https://<LINK_HOST>/
**Privacy Policy URL:** https://<LINK_HOST>/privacy
**License agreement:** custom EULA pointing to https://<LINK_HOST>/terms (it carries the six rules and the zero-tolerance clause for objectionable content and abusive users).
**Copyright:** 2026 Waypoints

**Screenshots:** `tools/screenshots/shots.sh` writes the 6.9" (iPhone 16 Pro Max, 1320 × 2868) and 6.5" (iPhone 11 Pro Max, 1242 × 2688) sets to `.build/screenshots/<size>/`, in upload order: map with friends, meet, route preview with low-car scoring, mod simulator, garage car, Showdown, team channel, market.

## Review notes

Paste into App Review Information, Notes.

**Location.** Location puts the user on the map for people they choose. Defaults: friends precise, teams approximate, nearby strangers hidden. Approximate positions are snapped on the server to a roughly half-mile area before they leave it, so a viewer who is not entitled to precise location never receives it. Ghost mode hides the user from everyone; home zones (stored only on the device) cap everyone at approximate. Background location ("Always") is requested only when the user turns on "Keep sharing when the app is closed" in Privacy and location; it stops after 5 minutes parked. Live positions are relayed in real time and never written to a database; there is no location history on the server. The server stores one coarse cell (about 5 km²) per user, for "meets near me" notifications. Joining a convoy first says "Everyone in the convoy sees your exact location until you leave."

**Help requests.** "Ask for a hand" (add menu) posts the user's exact position for up to 60 minutes. Before posting, the sheet says: "This shares your exact spot with the people you pick until you clear it. For an emergency, call emergency services." It is shown to friends and teammates; a switch, off by default, also shows it to drivers nearby as "A driver needs a hand" with no name. It is stored until the user taps "I'm good" or it expires. Home zones do not apply, and the sheet says so when posting from inside one.

**Speed.** The user's own speed appears only on their own navigation screen. It is never sent to other users and is never shown for anyone else. Convoy members are listed by time gap ("+40 s"), never speed. Drive recording for road ratings stays on the device; only a stretch the user chooses to save is uploaded.

**Racing.** The Strip is a virtual drag strip game. The lobby, the time slip, and shared images all say "virtual". It reads no GPS, real speed, or real location. Nothing on the map refers to racing, and no challenge can reference a place or time. Results feed only cosmetic marker icons. There is no police checkpoint report kind; speed cameras are fixed, permanent map items.

**User content (guideline 1.2).** Terms with the six rules are accepted before any content is shown. A text filter runs on messages, comments, captions, titles, names, and handles before sending. Every person, post, comment, message, listing, meet, map report, spot, road, car, and team can be reported with a reason. A person can be blocked from their profile, from the map, and from any message; their content disappears for the blocker at once, in both directions. A reported item disappears for the reporter at once; three reports from different people within 7 days hide it from everyone until reviewed. Reports land in a moderation queue reviewed within 24 hours, using four server functions: `moderation_hide`, `moderation_restore`, `moderation_suspend`, `moderation_unsuspend`. A suspended account cannot write or connect. Contact: support@waypoints.app, shown in Settings, About.

**Marketplace.** No payments, checkout, shipping, or fees. Every listing says "Meet in a public place. Waypoints doesn't handle payment."

**Account deletion.** Settings, Account, Delete account.

**Background modes.** `location` (the opt-in sharing above and turn-by-turn navigation), `audio` (voice channels and navigation prompts continue in the background), `remote-notification` (meet changes and messages).

**Sign in and demo account.** Sign in with Apple works with the reviewer's own Apple ID. For email sign-in, use the demo account below: it is a one-time code sent by email, so the notes include the webmail login for the demo mailbox. The demo account is a member of a team with seeded friends, a car with a build log, a meet, and a listing, so every screen has content. To see two people on the map, sign in on a second device with Sign in with Apple and add the demo user (handle below) as a friend.

```
Email: appreview@<LINK_HOST>
Mailbox: <webmail URL>, password <set by owner>
Handle: appreview
```

## Age rating questionnaire

PRD SAFE-10 sets a minimum age of 17, asked at sign-up. Answers:

| Question | Answer |
|---|---|
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Profanity or crude humor | Infrequent/Mild (user content, filtered) |
| Mature or suggestive themes | None |
| Horror or fear themes | None |
| Medical or treatment information | None |
| Alcohol, tobacco, or drug use or references | None |
| Simulated gambling | None |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Contests | None (Showdown votes award nothing of value) |
| Gambling (real money) | No |
| Unrestricted web access | No |
| User-generated content | Yes |
| Messaging and chat | Yes |
| Advertising | No |
| Parental controls | No |
| Age assurance | Yes: birth year asked at sign-up, under 17 cannot continue |
| Made for Kids | No |

Rating: choose the age-rating override so the store rating is at least the in-app gate: **17+** (or **18+** where the questionnaire offers 4+, 9+, 13+, 16+, 18+, since 16+ would sit below the gate).

## App Privacy (nutrition label)

**Tracking:** No. No analytics or advertising SDKs, no IDFA, no data brokers. `NSPrivacyTracking` is false.

**Data collected, all "Linked to you", all for "App Functionality" only, none used for tracking.** Each matches an entry in `ios/App/PrivacyInfo.xcprivacy` and a table in `supabase/migrations`.

| Label category | Data type | What and where |
|---|---|---|
| Contact Info | Email Address | Sign-in one-time codes (Supabase auth). |
| Contact Info | Name | Display name on the profile (`profiles.display_name`). |
| Location | Precise Location | Help requests (`help_requests.geom`, until cleared or 60 min) and map reports (`reports`), at the position the user posts. |
| Location | Coarse Location | One cell per user for meets-nearby alerts (`user_presence_cell`); spots store a city and cell only. |
| User Content | Emails or Text Messages | Direct, group, and team messages (`messages`). |
| User Content | Photos or Videos | Car photos, spots, listing photos, feed videos, avatars (Supabase storage). |
| User Content | Other User Content | Posts, comments, meets, venue notes, listings, cars and builds, roads and ratings, Showdown entries, virtual Strip runs, content reports. |
| Identifiers | User ID | Account id and handle. |
| Identifiers | Device ID | The APNs push token, if notifications are allowed (`device_tokens`). |
| Other Data | Other Data Types | Birth year, for the age gate (`profiles.birth_year`). |

**Not collected:** Health, Financial Info, Contacts, Browsing or Search History (search runs through Apple MapKit on the device; recents are stored on the device only), Purchases, Sensitive Info, Audio Data (voice is relayed live through LiveKit and not recorded), Usage Data and Diagnostics (MetricKit payloads stay on the device and reach the developer only through Apple's own opt-in sharing). Live location is relayed in real time and not stored, so beyond the rows above it is not "collected" in Apple's sense. Drive traces stay on the device unless a stretch is saved as a road.

**Third parties:** Supabase (database, auth, storage) and LiveKit (voice relay) process data only as service providers. Apple Maps for maps and routes.

## Required-reason APIs (privacy manifest)

| Category | Reason | Used for |
|---|---|---|
| User defaults | CA92.1 | Settings, map layers, recents, the current convoy, ladder progress, catalog version. |
| File timestamp | C617.1 | `FileManager.attributesOfItem` on an exported clip in the app container. |

No system boot time, disk space, or active keyboard APIs are called by app code. Swift packages ship their own manifests.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `false` in `Info.plist`. The app uses only encryption provided by the operating system (HTTPS, TLS WebSockets) and the standard WebRTC DTLS-SRTP in LiveKit for voice, which is exempt. No proprietary cryptography. Answer "No" to "Does your app use encryption beyond exempt" and no export documentation is needed.

## Release build

`make archive` writes a Release archive to `.build/Waypoints.xcarchive`. `ios/App/Config.xcconfig` must point at the hosted Supabase project and gateway (PRD 9.1) and set `LINK_HOST` before archiving. Upload with Xcode Organizer, or `xcodebuild -exportArchive` with an App Store Connect export options plist.
