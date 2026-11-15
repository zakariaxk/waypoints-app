-- W11-H: database hardening pass (access rules, storage, indexes, bounds, input checks).
--
-- 1. Missing verb coverage: spots had no delete path (the client's deleteSpot was always
--    refused); post_photos kept unused grants; several tables let a signed-in user write
--    columns that are server-owned (created_at, on_the_way_until, resolved_at).
-- 2. Storage: each bucket gets a SQL file-size and MIME allow-list to match
--    config.toml. The objects read policy is unchanged (W9-H): `messages` stays
--    owner-folder only; every bucket is still public by URL — see the section 2 note.
-- 3. Indexes for foreign keys that had none (cascade/set-null scans and the lookups the
--    client and gateway already issue).
-- 4. Bounds: build_costs and team_standings could return unbounded sets; new RPCs
--    following_feed / saved_listings / channel_unread give the client bounded queries.
-- 5. Input checks: length/range/size constraints on user-written columns that had none.
--
-- Migration order note: this file is timestamped 20261115080000, which sorts before
-- w10-6 (20261115090000) and w10-8 (20261115100000). Objects those migrations create
-- (car_of_week_runs, message_reactions) cannot be referenced here, so their indexes
-- and input checks live in 20261115110000_w11-h-2_car_of_week.sql.

set search_path = public, extensions;

-- 1. Policies and column grants ------------------------------------------------

-- spots: the client deletes its own spots (LiveMapContent.deleteSpot); the verb was
-- revoked in W0-C with no policy, so every delete was refused.
grant delete on public.spots to authenticated;
create policy spots_delete_own on public.spots
  for delete to authenticated
  using (spotter_id = auth.uid());

-- post_photos: read + insert only. Drop the unused verbs and anon's default grant.
revoke update, delete on public.post_photos from authenticated;
revoke all on public.post_photos from anon;

-- follows / listing_saves: insert + delete only (no legitimate update path).
revoke update on public.follows, public.listing_saves from authenticated;

-- Server-owned columns must not be client-writable. Column-level INSERT grants below
-- name exactly the columns each client payload sends; anything else (created_at,
-- resolved_at, on_the_way_until, waitlisted_at, like_count, hidden_at, id) falls back
-- to its default or is refused. UPDATE grants mirror the upsert payloads (PostgREST
-- sets every column it was sent, keys included).

revoke insert, update on public.meet_rsvps from authenticated;
grant insert (meet_id, user_id, status, car_id) on public.meet_rsvps to authenticated;
grant update (meet_id, user_id, status, car_id) on public.meet_rsvps to authenticated;
-- on_the_way_until stays gateway-only (NAV-15); waitlisted_at is trigger-owned.

revoke insert on public.meet_votes from authenticated;
grant insert (meet_id, voter_id, car_id) on public.meet_votes to authenticated;
-- created_at stays server-set; settle_peoples_choice breaks ties on it.

revoke insert on public.content_reports from authenticated;
grant insert (reporter_id, target_kind, target_id, reason, note) on public.content_reports to authenticated;
-- resolved_at and created_at stay server-set.

revoke insert on public.posts from authenticated;
grant insert (author_id, car_id, meet_id, video_path, poster_path, caption, duration_ms)
  on public.posts to authenticated;
-- created_at feeds the for-you score; like_count/comment_count/hidden_at are trigger-owned.

revoke insert on public.post_comments from authenticated;
grant insert (post_id, author_id, body) on public.post_comments to authenticated;

revoke insert on public.post_likes from authenticated;
grant insert (post_id, user_id) on public.post_likes to authenticated;

revoke insert on public.follows from authenticated;
grant insert (follower_id, followee_id) on public.follows to authenticated;

revoke insert on public.friendships from authenticated;
grant insert (requester_id, addressee_id) on public.friendships to authenticated;

revoke insert on public.listing_saves from authenticated;
grant insert (listing_id, user_id) on public.listing_saves to authenticated;

revoke insert on public.device_tokens from authenticated;
grant insert (user_id, apns_token, environment) on public.device_tokens to authenticated;

revoke insert on public.messages from authenticated;
grant insert (channel_id, thread_id, author_id, body, attachment_path) on public.messages to authenticated;

revoke insert on public.threads from authenticated;
grant insert (kind, listing_id, a_id, b_id) on public.threads to authenticated;

revoke insert, update on public.read_markers from authenticated;
grant insert (user_id, channel_id, thread_id, last_read_message_id) on public.read_markers to authenticated;
grant update (user_id, channel_id, thread_id, last_read_message_id) on public.read_markers to authenticated;

-- Future tables should not inherit anon's default privileges (RLS still applies).
alter default privileges in schema public revoke all on tables from anon;

-- 2. Storage --------------------------------------------------------------------
--
-- The storage.objects read policy stays as W9-H left it: every bucket is public, so
-- non-messages objects are already fetchable by URL; the policy's real job is keeping
-- `messages` (DM attachments) unenumerable — foldername[1] must equal the caller. All
-- buckets remain public by URL, which means a DM attachment URL is bearer-accessible
-- to anyone who obtains it; moving `messages` to a private bucket needs signed-URL
-- downloads in the feature layer and is tracked as follow-up work, not this pass.
-- What this migration adds is SQL-side enforcement the bucket flag cannot give:
-- per-bucket size caps and MIME allow-lists matching what the client uploads.

update storage.buckets
   set file_size_limit = 15728640,
       allowed_mime_types = '{image/jpeg,image/png,image/heic,image/webp}'
 where id in ('avatars', 'cars', 'listings', 'spots', 'teams', 'messages');
update storage.buckets
   set file_size_limit = 15728640,
       allowed_mime_types = '{image/jpeg,image/png,image/heic,image/webp,video/mp4,video/quicktime}'
 where id = 'posts';
update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = '{application/json,application/octet-stream,application/gzip,application/x-gzip,application/x-sqlite3,application/vnd.sqlite3}'
 where id = 'catalog';

-- 3. Indexes --------------------------------------------------------------------

-- Foreign keys with no index: cascade/set-null deletes and the lookups the client and
-- gateway already issue would otherwise scan the whole table.
create index if not exists profiles_primary_car_idx on public.profiles (primary_car_id) where primary_car_id is not null;
create index if not exists reports_author_idx on public.reports (author_id);
create index if not exists meets_host_idx on public.meets (host_id);
create index if not exists meets_team_idx on public.meets (team_id) where team_id is not null;
create index if not exists meets_road_idx on public.meets (road_id) where road_id is not null;
create index if not exists meets_winner_idx on public.meets (winner_car_id) where winner_car_id is not null;
create index if not exists meet_rsvps_car_idx on public.meet_rsvps (car_id) where car_id is not null;
create index if not exists meet_rsvps_waitlist_idx on public.meet_rsvps (meet_id, waitlisted_at, user_id) where status = 'waitlist';
create index if not exists meet_checkins_user_idx on public.meet_checkins (user_id);
create index if not exists meet_votes_voter_idx on public.meet_votes (voter_id);
create index if not exists meet_votes_car_fk_idx on public.meet_votes (car_id);
create index if not exists meet_promotions_user_idx on public.meet_promotions (user_id);
create index if not exists venue_notes_author_idx on public.venue_notes (author_id);
create index if not exists roads_author_idx on public.roads (author_id, created_at desc);
create index if not exists road_ratings_user_idx on public.road_ratings (user_id);
create index if not exists listings_car_idx on public.listings (car_id) where car_id is not null;
create index if not exists threads_listing_idx on public.threads (listing_id) where listing_id is not null;
create index if not exists posts_car_idx on public.posts (car_id) where car_id is not null;
create index if not exists read_markers_channel_idx on public.read_markers (channel_id) where channel_id is not null;
create index if not exists read_markers_thread_idx on public.read_markers (thread_id) where thread_id is not null;
create index if not exists race_results_car_idx on public.race_results (car_id, created_at desc);
create index if not exists help_responses_user_idx on public.help_responses (user_id);
create index if not exists showdown_votes_winner_idx on public.showdown_votes (winner_car_id);
create index if not exists showdown_votes_loser_idx on public.showdown_votes (loser_car_id);
create index if not exists notifications_actor_idx on public.notifications (actor_id) where actor_id is not null;
create index if not exists content_reports_reporter_idx on public.content_reports (reporter_id);
create index if not exists post_comments_author_idx on public.post_comments (author_id);
create index if not exists teams_owner_idx on public.teams (owner_id);
create index if not exists messages_author_idx on public.messages (author_id);
create index if not exists report_votes_user_idx on public.report_votes (user_id);
create index if not exists help_requests_requester_idx on public.help_requests (requester_id);
-- The gateway deletes stale rows by apns_token alone (PK leads with user_id).
create index if not exists device_tokens_apns_idx on public.device_tokens (apns_token);

-- Tables created by w10-6 / w10-8 sort after this file, so their missing FK indexes and
-- input checks live in 20261115110000_w11-h-2_car_of_week.sql instead.

-- 4. Bounds on set-returning RPCs ----------------------------------------------

-- build_costs: one row per costed entry; cap it like every other list RPC.
create or replace function public.build_costs(car uuid)
returns table (entry_id uuid, cost_cents int)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select e.id, e.cost_cents
  from public.build_entries e
  where e.car_id = car
    and e.cost_cents is not null
    and public.car_owner(car) = auth.uid()
  limit 500;
$$;

revoke execute on function public.build_costs(uuid) from public, anon;
grant execute on function public.build_costs(uuid) to authenticated;

-- team_standings: rank() ties could return more than 100 public rows; bound the public
-- slice with row_number while keeping rank() for display.
create or replace function public.team_standings(team uuid default null)
returns table (team_id uuid, name text, tag text, icon_path text, score int, rank int)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with bounds as (
    select date_trunc('week', now() at time zone 'utc') at time zone 'utc' as s
  ),
  scored as (
    select m.team_id, count(*)::int as score
    from public.showdown_votes v
    join public.cars c on c.id = v.winner_car_id
    join public.team_members m on m.user_id = c.owner_id
    cross join bounds b
    where v.created_at >= b.s
      and v.created_at < b.s + interval '7 days'
      and c.hidden_at is null
      and not public.is_suspended(c.owner_id)
    group by m.team_id
  ),
  ranked as (
    select t.id, t.name, t.tag, t.icon_path, t.is_public, s.score,
           (rank() over (order by s.score desc))::int as rank,
           (row_number() over (order by s.score desc, t.name))::int as rn
    from scored s
    join public.teams t on t.id = s.team_id
    where t.hidden_at is null
  )
  select r.id, r.name, r.tag, r.icon_path, r.score, r.rank
  from ranked r
  where public.is_team_member(r.id)
     or (r.is_public and (r.rn <= 100 or r.id = team_standings.team))
  order by r.rank, r.name;
$$;

revoke all on function public.team_standings(uuid) from public, anon;
grant execute on function public.team_standings(uuid) to authenticated, service_role;

-- New bounded RPCs the client uses instead of unbounded `in` lists and N+1 loops.

-- The following feed: posts by people the caller follows, newest first. Replaces a
-- followee-id `in` filter that could not fit in a URL. Same visibility rules as
-- posts_read (blocks and hidden/suspended authors drop out).
create function public.following_feed(before timestamptz default null, lim int default 20)
returns setof public.posts
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select po.*
  from public.posts po
  join public.follows f on f.followee_id = po.author_id and f.follower_id = auth.uid()
  where auth.uid() is not null
    and not public.is_blocked_pair(po.author_id, auth.uid())
    and public.content_visible(po.author_id, po.hidden_at)
    and (before is null or po.created_at < following_feed.before)
  order by po.created_at desc, po.id
  limit least(greatest(coalesce(following_feed.lim, 20), 1), 50);
$$;

revoke execute on function public.following_feed(timestamptz, int) from public, anon;
grant execute on function public.following_feed(timestamptz, int) to authenticated, service_role;

-- The caller's saved listings, newest save first. listings_read is `using (true)`
-- (moderation is the 'removed' status the client filters), so no extra visibility
-- clause is needed here. Replaces an `in` filter over every saved id.
create function public.saved_listings(lim int default 200)
returns setof public.listings
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select l.*
  from public.listings l
  join public.listing_saves s on s.listing_id = l.id and s.user_id = auth.uid()
  where auth.uid() is not null
  order by s.created_at desc
  limit least(greatest(coalesce(saved_listings.lim, 200), 1), 500);
$$;

revoke execute on function public.saved_listings(int) from public, anon;
grant execute on function public.saved_listings(int) to authenticated, service_role;

-- Unread channel-message counts for the caller in one query (was one query per channel).
-- Only channels of teams the caller belongs to, matching messages_read; messages from
-- blocked or hidden authors do not count.
-- or replace: w10-8 (which sorts after this file) replaces this body with a
-- mute-aware version of the same signature; either way the grants below hold.
create or replace function public.channel_unread()
returns table (channel_id uuid, unread_count int)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with my_channels as (
    select c.id as channel_id
    from public.channels c
    join public.team_members m on m.team_id = c.team_id and m.user_id = auth.uid()
  ),
  reads as (
    select channel_id, last_read_message_id
    from public.read_markers
    where user_id = auth.uid() and channel_id is not null
  )
  select mc.channel_id, count(*)::int as unread_count
  from my_channels mc
  join public.messages msg on msg.channel_id = mc.channel_id
    and msg.deleted_at is null
    and msg.author_id <> auth.uid()
    and msg.id > coalesce((select r.last_read_message_id from reads r where r.channel_id = mc.channel_id), 0)
    and public.content_visible(msg.author_id, msg.hidden_at)
    and not public.is_blocked_pair(msg.author_id, auth.uid())
  group by mc.channel_id;
$$;

revoke execute on function public.channel_unread() from public, anon;
grant execute on function public.channel_unread() to authenticated, service_role;

-- 5. Input checks ---------------------------------------------------------------

-- Storage paths and remaining unbounded text/jsonb. NOT VALID + VALIDATE keeps the
-- add online on tables that may already hold rows.

alter table public.profiles
  add constraint profiles_avatar_path_len check (avatar_path is null or char_length(avatar_path) <= 300) not valid;
alter table public.profiles validate constraint profiles_avatar_path_len;

alter table public.car_photos
  add constraint car_photos_path_len check (char_length(path) <= 300) not valid;
alter table public.car_photos validate constraint car_photos_path_len;

alter table public.build_entries
  add constraint build_entries_photo_path_len check (photo_path is null or char_length(photo_path) <= 300) not valid;
alter table public.build_entries validate constraint build_entries_photo_path_len;
alter table public.build_entries
  add constraint build_entries_mod_id_len check (mod_id is null or char_length(mod_id) <= 100) not valid;
alter table public.build_entries validate constraint build_entries_mod_id_len;
alter table public.build_entries
  add constraint build_entries_cost_max check (cost_cents is null or cost_cents <= 100000000) not valid;
alter table public.build_entries validate constraint build_entries_cost_max;
alter table public.build_entries
  add constraint build_entries_happened_on_range check (happened_on between date '1900-01-01' and date '2100-12-31') not valid;
alter table public.build_entries validate constraint build_entries_happened_on_range;

alter table public.posts
  add constraint posts_video_path_len check (video_path is null or char_length(video_path) <= 300) not valid;
alter table public.posts validate constraint posts_video_path_len;
alter table public.posts
  add constraint posts_poster_path_len check (poster_path is null or char_length(poster_path) <= 300) not valid;
alter table public.posts validate constraint posts_poster_path_len;

alter table public.listing_photos
  add constraint listing_photos_path_len check (char_length(path) <= 300) not valid;
alter table public.listing_photos validate constraint listing_photos_path_len;

alter table public.spots
  add constraint spots_photo_path_len check (photo_path is null or char_length(photo_path) <= 300) not valid;
alter table public.spots validate constraint spots_photo_path_len;
alter table public.spots
  add constraint spots_catalog_model_id_pos check (catalog_model_id is null or catalog_model_id > 0) not valid;
alter table public.spots validate constraint spots_catalog_model_id_pos;

alter table public.messages
  add constraint messages_attachment_path_len check (attachment_path is null or char_length(attachment_path) <= 300) not valid;
alter table public.messages validate constraint messages_attachment_path_len;

alter table public.teams
  add constraint teams_icon_path_len check (icon_path is null or char_length(icon_path) <= 300) not valid;
alter table public.teams validate constraint teams_icon_path_len;

alter table public.cars
  add constraint cars_spec_overrides_size check (octet_length(spec_overrides::text) <= 4000) not valid;
alter table public.cars validate constraint cars_spec_overrides_size;
alter table public.cars
  add constraint cars_mods_size check (octet_length(mods::text) <= 4000) not valid;
alter table public.cars validate constraint cars_mods_size;

alter table public.race_results
  add constraint race_results_mods_size check (octet_length(mods::text) <= 4000) not valid;
alter table public.race_results validate constraint race_results_mods_size;
alter table public.race_results
  add constraint race_results_reaction_ms_range check (reaction_ms is null or reaction_ms between 0 and 60000) not valid;
alter table public.race_results validate constraint race_results_reaction_ms_range;
alter table public.race_results
  add constraint race_results_trap_max check (trap_mph_x10 is null or trap_mph_x10 <= 10000) not valid;
alter table public.race_results validate constraint race_results_trap_max;
alter table public.race_results
  add constraint race_results_sixty_max check (sixty_ft_ms is null or sixty_ft_ms <= 60000) not valid;
alter table public.race_results validate constraint race_results_sixty_max;
alter table public.race_results
  add constraint race_results_model_version_max check (model_version is null or model_version <= 100) not valid;
alter table public.race_results validate constraint race_results_model_version_max;

alter table public.showdown_entries
  add constraint showdown_entries_rating_range check (rating between 0 and 10000) not valid;
alter table public.showdown_entries validate constraint showdown_entries_rating_range;

alter table public.listings
  add constraint listings_price_max check (price_cents <= 100000000) not valid;
alter table public.listings validate constraint listings_price_max;

alter table public.convoys
  add constraint convoys_id_len check (char_length(id) between 1 and 64) not valid;
alter table public.convoys validate constraint convoys_id_len;
alter table public.convoys
  add constraint convoys_join_code_fmt check (join_code ~ '^[A-Za-z0-9]{6,32}$') not valid;
alter table public.convoys validate constraint convoys_join_code_fmt;
alter table public.convoys
  add constraint convoys_state_size check (octet_length(state::text) <= 2097152) not valid;
alter table public.convoys validate constraint convoys_state_size;

-- car_of_week_runs (w10-6) sorts after this file; its input checks and the missing
-- user_id index on it and message_reactions (w10-8) are in
-- 20261115110000_w11-h-2_car_of_week.sql.
