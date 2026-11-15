# Database hardening audit (W11-H)

Scope: `supabase/**` — RLS, grants, `SECURITY DEFINER` functions, storage buckets,
migration ordering, indexes for client/gateway queries, bounded list queries, and
database-level input checks. Fixes live in
`supabase/migrations/20261115080000_w11-h_database.sql` and
`supabase/migrations/20261115110000_w11-h-2_car_of_week.sql`, with matching rows in
`supabase/checks.sql` (the `w11h:` block before the cascade section).

Verification status: static review plus `checks.sql` additions. `make check-db`
(local Supabase stack) and `make build` were **not** run in this pass — see "What the
parent must run" at the end.

## Item 1 — RLS, policies, grants, security-definer functions

**Verdict: PASS with fixes.** Every public table has RLS enabled (already asserted by
the `rls: enabled on every public table` check) and the W9-H pass had already added
`suspended_write_guard` to every RLS table, restricted `is_blocked_pair`/`are_friends`,
and revoked `anon` execute on security-definer functions. The remaining gaps found and
fixed in `20261115080000_w11-h_database.sql`:

- `spots` had **no delete policy** — the client's `deleteSpot` was always refused.
  Added `spots_delete_own` (owner only) plus the `delete` grant.
- `post_photos` kept unused `update`/`delete` grants and `anon`'s default grant —
  revoked.
- `follows` / `listing_saves` allowed `update` with no legitimate path — revoked.
- Server-owned columns were client-writable through table-level INSERT grants:
  `meet_rsvps.on_the_way_until` / `waitlisted_at`, `meet_votes.created_at`,
  `content_reports.resolved_at`, `posts.created_at`/`like_count`/`hidden_at`,
  `post_comments`, `post_likes`, `follows`, `friendships`, `listing_saves`,
  `device_tokens` extras, plus `messages.created_at`, `threads.id`/`created_at`, and
  `read_markers.created_at`. INSERT/UPDATE is now column-level, naming exactly the
  columns each client payload sends (`messages`, `threads`, `read_markers` included).
- `alter default privileges … revoke all on tables from anon` so future tables do
  not inherit anon's default grant (RLS still applies; this removes the grant itself).

`SECURITY DEFINER` functions: all existing ones already set `search_path` and are
granted only to `authenticated`/`service_role`. The three re-defined functions
(`build_costs`, `team_standings`) keep `set search_path` and re-issue the same
revokes/grants. New RPCs (`following_feed`, `saved_listings`, `channel_unread`) are
`security definer`, `set search_path = public, extensions, pg_temp`, revoked from
`public`/`anon`, granted to `authenticated`/`service_role`.

### RLS audit table (all 52 public tables)

| Table | RLS | Read | Write | Notes |
|---|---|---|---|---|
| profiles | on | own + visible others | own columns | handle/bio/etc. length checks |
| cars | on | visible | owner | `spec_overrides`/`mods` JSONB ≤ 4 KB (new) |
| car_photos | on | via car visibility | owner | path ≤ 300 (new) |
| build_entries | on | via car | owner | title/body/cost/date caps (new) |
| teams | on | public or member | owner/role perms | icon_path ≤ 300 (new) |
| team_roles | on | member | role `manage_roles` | permissions bitset check |
| team_members | on | member | owner/role perms | role must share team (composite FK) |
| channels | on | member | role perms | kind/slug checks |
| meets | on | visibility rules | host/gateway | capacity, time order (W10-2) |
| meet_rsvps | on | meet readers | own RSVP | **column grants (new)** |
| meet_votes | on | meet readers | own vote | **column grants (new)** |
| meet_checkins | on | meet readers | service only | gateway-written |
| meet_promotions | on | none (service) | trigger only | waitlist promotion audit |
| reports | on | region/bbox RPC | gateway | author idx (new) |
| report_votes | on | service only | service only | user idx (new) |
| roads | on | public | author | author idx (new) |
| road_ratings | on | public | own rating | user idx (new) |
| road_loops | on | owner/share RPC | owner | owner idx (W10-9) |
| spots | on | public | own | **delete policy (new)** |
| venue_notes | on | public | author | author idx (new) |
| listings | on | active + visibility | seller | price cap (new) |
| listing_photos | on | via listing | seller | path ≤ 300 (new) |
| listing_saves | on | own | own | **update revoked (new)** |
| threads | on | participants | participants | a/b/listing idx |
| messages | on | participants | author | attachment_path ≤ 300 (new) |
| read_markers | on | own | own | channel/thread idx (new) |
| posts | on | visibility rules | author | **column grants (new)** |
| post_photos | on | via post | post author | **update/delete/anon revoked (new)** |
| post_likes | on | via post | own | **column grants (new)** |
| post_comments | on | via post | author | **column grants (new)** |
| follows | on | own | own | **update revoked, column insert (new)** |
| friendships | on | participants | participants | **column insert (new)** |
| blocks | on | own | own | PK covers both directions |
| notifications | on | own | trigger/service | actor idx (new) |
| notification_prefs | on | own | own | PK user_id |
| achievements | on | **anon + auth** | trigger/service | only intentional anon grant |
| content_reports | on | service only | reporter | **column insert (new)** |
| race_results | on | public | own car | range/size caps (new) |
| help_requests | on | requester+friends/teams | requester | requester idx (new) |
| help_responses | on | via request | responder | user idx (new) |
| device_tokens | on | own | own | **column insert, apns idx (new)** |
| privacy_settings | on | own | own | PK user_id |
| user_presence_cell | on | gateway/service | gateway | h3 idx |
| convoys | on | service only | service only | id/join_code/state checks (new) |
| showdown_entries | on | public | owner/gateway | rating range (new) |
| showdown_votes | on | own | own | winner/loser idx (new) |
| car_of_week_pool | on | service only | service only | — |
| car_of_week_picks | on | service only | service only | — |
| car_of_week_runs | on | via RPCs only | via RPCs | user idx + caps (w11-h-2) |
| message_reactions | on | via messages | own | user idx (w11-h-2) |
| mutes | on | own | own | PK owner-led |

## Item 3 — Storage buckets

**Verdict: PASS with one documented limitation.**

| Bucket | public | Objects read policy | Insert/Update/Delete | Size limit | MIME allow-list |
|---|---|---|---|---|---|
| avatars | yes | all (W9-H) | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| cars | yes | all | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| posts | yes | all | own folder | 15 MiB (new) | + mp4/quicktime (new) |
| listings | yes | all | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| spots | yes | all | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| teams | yes | all | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| messages | yes | **own folder only** | own folder | 15 MiB (new) | jpeg/png/heic/webp (new) |
| catalog | yes | service-managed | service only | 50 MiB (new) | json/octet-stream/gzip/sqlite (new) |

`storage.objects` SELECT stays as W9-H defined it: non-`messages` buckets are
enumerable (they are public by URL anyway), `messages` objects are readable only when
the first path folder equals `auth.uid()`. Insert/update/delete already require
authenticated ownership of the first folder.

**Resolved (W11-H-5, `20261115140000_w11-h-5_private_messages_bucket.sql`):** the
`messages` bucket is now `public = false` and its objects are readable only by the
uploader's own folder or by a caller who can read the `messages` row pointing at the
path (thread party / channel member). The client resolves attachments through
`signedURL` (1 h expiry) in `MessagingFeature`; verified live against the local
stack. The other seven buckets stay public by design (map/feed/market content is
visible to non-friends; `catalog` is fetched session-less).

## Item 7 — Migration ordering and signatures

**Verdict: PASS.** Filenames sort cleanly; the six newest W10 migrations were reviewed:

- `20261115020000_w10-2_meet_capacity` — adds `meet_promotions`, `waitlisted_at`,
  capacity trigger/function; depends only on W0 tables. OK.
- `20261115030000_w10-4_build_cost` — column-level privileges hiding `cost_cents`;
  `build_costs(car)` RPC. Signature `(uuid)`; re-defined identically in W11-H with a
  `limit 500`. OK.
- `20261115040000_w10-5_saved_builds` — `saved_builds` JSONB + constraints; no new
  objects. OK.
- `20261115050000_w10-7_team_standings` — `team_standings(team uuid default null)`;
  W11-H `create or replace` keeps the identical return shape and adds a
  `row_number()` bound for the public slice. OK.
- `20261115060000_w10-9_road_loops` — `road_loops` + `road_loop(uuid)` RPC; owner idx
  present. OK.
- `20261115070000_w10-10_export_my_data` — `export_my_data()` aggregates the caller's
  data into one JSONB document. **Boundedness note:** it is a full data export by
  design (GDPR-style); it cannot be row-capped without breaking the contract. Per-user
  data is inherently bounded by the per-table caps added elsewhere. Accepted as-is;
  documented here so the unbounded-RPC audit has a deliberate exception.
- `20261115100000_w10-8_reactions_mute` — sorts after W11-H and contains its own
  `create or replace function public.channel_unread()` (same signature, adds mute
  filtering). W11-H's `create or replace` + grants are compatible; the w10-8 body is
  the one that survives a full reset. Verified no signature conflict.
- `20261115090000_w10-6_car_of_week` — `car_of_week_runs` has **no primary key** and
  `user_id`/`message_reactions.user_id` had no indexes; both live in W11-H-2 because
  the tables do not exist at W11-H's timestamp. Adding a PK to `car_of_week_runs`
  would need a dedupe decision — left as follow-up (the table is append-mostly via
  `car_of_week_save`).

No duplicate object names found across migrations; every `create or replace` keeps
the prior signature (`build_costs(uuid)`, `team_standings(uuid)`).

## Item 8 — Query/index audit

**Verdict: PASS with fixes.** Audited every PostgREST call in the permitted
`Live*.swift` repositories and every SQL statement in `server/internal` (gateway).

Indexes added in W11-H for FKs that had none (cascade/set-null scans and the lookups
above): `profiles_primary_car_idx`, `reports_author_idx`, `meets_host_idx`,
`meets_team_idx`, `meets_road_idx`, `meets_winner_idx`, `meet_rsvps_car_idx`,
`meet_rsvps_waitlist_idx` (partial, waitlist promotion), `meet_checkins_user_idx`,
`meet_votes_voter_idx`, `meet_votes_car_fk_idx`, `meet_promotions_user_idx`,
`venue_notes_author_idx`, `roads_author_idx`, `road_ratings_user_idx`,
`listings_car_idx`, `threads_listing_idx`, `posts_car_idx`,
`read_markers_channel_idx`, `read_markers_thread_idx`, `race_results_car_idx`,
`help_responses_user_idx`, `showdown_votes_winner_idx`, `showdown_votes_loser_idx`,
`notifications_actor_idx`, `content_reports_reporter_idx`, `post_comments_author_idx`,
`teams_owner_idx`, `messages_author_idx`, `report_votes_user_idx`,
`help_requests_requester_idx`, `device_tokens_apns_idx` (gateway deletes by
`apns_token` alone). W11-H-2 adds `car_of_week_runs_user_idx` and
`message_reactions_user_idx` (PKs lead with other columns).

Gateway queries verified against these indexes: `meets` by host/series/ends_at,
`meet_rsvps`/`meet_checkins`/`meet_promotions` by meet_id (PK-leading) and user_id,
`report_votes` by report_id (PK-leading), `notifications` by user_id,
`user_presence_cell`/`reports`/`help_requests` by h3/geom (GiST + btree already
present), `friendships`/`blocks`/`team_members` joins (PK/secondary idx present),
`device_tokens` by apns_token (new), `convoys` by join_code (existing partial idx;
the `state->'member_uids' @>` containment probe is a jsonb scan on a small table —
accepted).

## Item 9 — Bounded list queries

**Verdict: PASS with fixes.** Every list read in the permitted Backend files now has
a `limit`, cursor, `single()`, or is chunked. Fixes made:

- `LiveMapContent`: `upcomingMeets` RSVP fan-in capped at newest 100 (keeps the `in`
  filter inside a URL); `summary(_ road:)` ratings capped at 10 000.
- `LivePeople`: friendship rows capped at 1000; pending requests at 200; profile/car
  fan-ins chunked at 100 ids per request.
- `LiveGarage`: `cars` 100, `photos` 200, `buildEntries` 500.
- `LiveSocial`: `myTeams`/members/roles/channels/meets/messages/threads/readMarkers/
  saved()/listings(by:)/posts/comments/raceResults/achievements/myProgress all
  bounded; `showdown_votes` judged-set capped at newest 1000; `rankings` clamps
  `limit` to 100 and batches contender lookups (was 3 queries per entry → 3 total).
- New server-side bounds (RPCs): `following_feed(before, lim ≤ 50)` replaces an
  unbounded followee `in` filter; `saved_listings(lim ≤ 500)` replaces an `in` over
  every saved id; `channel_unread()` replaces per-channel count queries;
  `build_costs` capped at 500; `team_standings` public slice capped at 100 via
  `row_number()` while keeping `rank()` for display.
- `export_my_data()` is the deliberate exception (item 7 note).

`LiveW10*.swift` and `LiveAuth.swift` were read-only; their queries were audited —
W10 list calls already carry limits or go through the bounded RPCs above.

## Item 10 — Database-level input checks

**Verdict: PASS with fixes.** W0 already constrained most user-written text (handles,
names, captions, bodies, notes, prices, years, hex colors, JSONB types). W11-H adds
the missing length/range/size checks, all `NOT VALID` + `VALIDATE` so they apply
online:

- Storage paths ≤ 300 chars: `profiles.avatar_path`, `car_photos.path`,
  `build_entries.photo_path`, `posts.video_path`/`poster_path`,
  `listing_photos.path`, `spots.photo_path`, `messages.attachment_path`,
  `teams.icon_path`.
- JSONB/text size caps: `cars.spec_overrides`/`mods` ≤ 4 KB,
  `race_results.mods` ≤ 4 KB, `convoys.state` ≤ 2 MB, `build_entries.mod_id` ≤ 100.
- Ranges: `build_entries.cost_cents` ≤ 1 000 000 (cents), `happened_on` 1900–2100;
  `race_results.reaction_ms` 0–60000, `trap_mph_x10` ≤ 10000, `sixty_ft_ms` ≤ 60000,
  `model_version` ≤ 100; `listings.price_cents` ≤ 1 000 000; `showdown_entries.rating`
  0–10000; `car_of_week_runs` trap/reaction/model caps (w11-h-2).
- Formats: `convoys.id` 1–64, `convoys.join_code` `^[A-Za-z0-9]{6,32}$` (matches the
  existing `teams.invite_code` pattern);
  `spots.catalog_model_id` > 0 when present.

## What the parent must run

1. `make check-db` (needs `make dev` local stack) — executes the new `w11h:` checks;
   watch especially `w11h defaults: anon has no privileges on new public tables`
   (depends on the migration role matching the checks role) and the `w11h rpcs`
   privilege signature strings.
2. `make build` — the iOS gate; the Swift edits (bounded queries + three new RPC
   calls) are unverified by a compiler in this pass (`swift build` fails on macOS
   platform requirements, unrelated to the changes).
3. `git pull --rebase` before committing; commit as `W11-H: database hardening`.

## Files changed

- `supabase/migrations/20261115080000_w11-h_database.sql` (new)
- `supabase/migrations/20261115110000_w11-h-2_car_of_week.sql` (new)
- `supabase/checks.sql` (additive `w11h:` block before the cascade section)
- `ios/Packages/WaypointsKit/Sources/Backend/LiveMapContent.swift`
- `ios/Packages/WaypointsKit/Sources/Backend/LivePeople.swift`
- `ios/Packages/WaypointsKit/Sources/Backend/LiveSocial.swift`
- `ios/Packages/WaypointsKit/Sources/Backend/LiveGarage.swift` (limits, earlier in
  this pass)
- `docs/hardening/database.md` (this file)
