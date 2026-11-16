-- W0-C: access rule checks (plan section 5).
--
-- Run against a local stack after `supabase db reset`:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -f supabase/checks.sql
--
-- Everything happens in one transaction that is rolled back, so the database
-- is unchanged afterwards. Three throwaway users are created: Avery (A) and
-- Blake (B) are the two users the rules are exercised as; Casey (C) is a
-- third party who gets blocked by A. Each statement runs as
-- `role authenticated` with request.jwt.claims set to the user, exactly as
-- PostgREST does. Output: one line per rule, the rule name then PASS or FAIL.

\set ON_ERROR_STOP 1
\pset tuples_only on
\pset format unaligned
\pset footer off
\set QUIET 1

begin;

-- Newer storage-api images guard storage.objects with protect_delete(); the checks
-- exercise RLS on that table directly, so allow it for this transaction only.
set local storage.allow_delete_query = 'true';

create temp table _checks (seq serial primary key, name text not null, ok boolean not null, detail text);

-- Switch to an actor: a user uuid, 'anon', or 'service'.
create function pg_temp.become(actor text) returns void
language plpgsql as $f$
begin
  if actor = 'anon' then
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    perform set_config('role', 'anon', true);
  elsif actor = 'service' then
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
    perform set_config('role', 'service_role', true);
  else
    perform set_config('request.jwt.claim.sub', actor, true);
    perform set_config('request.jwt.claims',
      json_build_object('sub', actor, 'role', 'authenticated')::text, true);
    perform set_config('role', 'authenticated', true);
  end if;
end $f$;

-- Run stmt as actor. A query (select/with) reports its row count; DML its
-- affected rows. Unless keep, the effect is rolled back. Errors are caught.
create function pg_temp.attempt(actor text, stmt text, keep boolean,
                                out n bigint, out err text)
language plpgsql as $f$
begin
  begin
    perform pg_temp.become(actor);
    if stmt ~* '^\s*(select|with)\s' then
      -- EXECUTE evaluates the whole query, target list included; wrapping it in
      -- count(*) would let the planner skip unused function calls entirely.
      execute stmt;
      get diagnostics n = row_count;
    else
      execute stmt;
      get diagnostics n = row_count;
    end if;
    if not keep then
      raise exception using errcode = 'WP001', message = 'undo';
    end if;
    reset role;
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claims', '', true);
  exception
    when sqlstate 'WP001' then err := null;
    when others then n := null; err := sqlstate || ' ' || sqlerrm;
  end;
end $f$;

-- PASS when stmt succeeds and touches or returns at least one row.
create function pg_temp.allow(name text, actor text, stmt text, keep boolean default false)
returns void language plpgsql as $f$
declare r record;
begin
  r := pg_temp.attempt(actor, stmt, keep);
  insert into _checks (name, ok, detail)
  values (name, r.err is null and r.n > 0, coalesce(r.err, r.n || ' rows'));
end $f$;

-- PASS when stmt is refused: zero rows, or an error whose SQLSTATE is listed.
-- 42501 covers missing privileges and row-level security violations.
create function pg_temp.deny(name text, actor text, stmt text, states text default '42501')
returns void language plpgsql as $f$
declare r record;
begin
  r := pg_temp.attempt(actor, stmt, false);
  insert into _checks (name, ok, detail)
  values (name,
          (r.err is null and r.n = 0) or left(r.err, 5) = any (string_to_array(states, ',')),
          coalesce(r.err, r.n || ' rows'));
end $f$;

-- PASS when a condition observed as the table owner holds.
create function pg_temp.truth(name text, ok boolean) returns void
language sql as $f$
  insert into _checks (name, ok, detail) values (name, coalesce(ok, false), null);
$f$;

do $do$
declare
  a constant text := 'cccccccc-0000-4000-8000-00000000000a';
  b constant text := 'cccccccc-0000-4000-8000-00000000000b';
  c constant text := 'cccccccc-0000-4000-8000-00000000000c';
  -- fixed ids for rows created during the run
  car_a   constant text := 'cccccccc-0000-4000-8001-00000000000a';
  car_a2  constant text := 'cccccccc-0000-4000-8001-0000000000a2';
  car_b   constant text := 'cccccccc-0000-4000-8001-00000000000b';
  car_c   constant text := 'cccccccc-0000-4000-8001-00000000000c';
  team_p  constant text := 'cccccccc-0000-4000-8002-000000000001';  -- private, owned by A
  team_o  constant text := 'cccccccc-0000-4000-8002-000000000002';  -- public, owned by A
  meet_pub constant text := 'cccccccc-0000-4000-8003-000000000001';
  meet_fr  constant text := 'cccccccc-0000-4000-8003-000000000002';
  meet_tm  constant text := 'cccccccc-0000-4000-8003-000000000003';
  post_a  constant text := 'cccccccc-0000-4000-8004-00000000000a';
  thr_ab  constant text := 'cccccccc-0000-4000-8005-0000000000ab';
  lst_a   constant text := 'cccccccc-0000-4000-8006-00000000000a';
  help_a  constant text := 'cccccccc-0000-4000-8009-00000000000a';
  general_p uuid;
  msg_b bigint;
  v_int int;
begin
  ---------------------------------------------------------------- sign-up
  insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data)
  values
    ('00000000-0000-0000-0000-000000000000', a::uuid, 'authenticated', 'authenticated', 'avery.check@waypoints.test',
     '{"provider":"email"}', '{"handle":"avery_check","display_name":"Avery Quinn"}'),
    ('00000000-0000-0000-0000-000000000000', b::uuid, 'authenticated', 'authenticated', 'blake.check@waypoints.test',
     '{"provider":"email"}', '{"handle":"blake_check","display_name":"Blake Soto"}'),
    ('00000000-0000-0000-0000-000000000000', c::uuid, 'authenticated', 'authenticated', 'casey.check@waypoints.test',
     '{"provider":"email"}', '{"handle":"Not A Handle"}');

  perform pg_temp.truth('signup: profile row created with handle from metadata',
    exists (select 1 from profiles where user_id = a::uuid and handle = 'avery_check' and display_name = 'Avery Quinn'));
  perform pg_temp.truth('signup: invalid metadata handle replaced with generated one',
    exists (select 1 from profiles where user_id = c::uuid and handle::text ~ '^driver_[0-9a-f]{12}$'));
  perform pg_temp.truth('signup: privacy defaults friends precise, team approx, nearby hidden',
    exists (select 1 from privacy_settings where user_id = a::uuid
            and friends_level = 'precise' and team_level = 'approx' and nearby_level = 'hidden'));

  ---------------------------------------------------------------- profiles
  perform pg_temp.allow('profiles: signed-in user reads another profile', b,
    format($s$select 1 from profiles where user_id = %L$s$, a));
  perform pg_temp.deny('profiles: anon cannot read profiles', 'anon',
    $s$select 1 from profiles$s$);
  perform pg_temp.allow('profiles: owner updates own profile', a,
    format($s$update profiles set bio = 'Weekend autocrosser' where user_id = %L$s$, a));
  perform pg_temp.deny('profiles: user cannot update another profile', b,
    format($s$update profiles set bio = 'hijacked' where user_id = %L$s$, a));
  perform pg_temp.deny('profiles: owner cannot change wire uid', a,
    format($s$update profiles set uid = 999999 where user_id = %L$s$, a), '42501,428C9');
  perform pg_temp.deny('profiles: handle must be 3-20 of [a-z0-9_]', a,
    format($s$update profiles set handle = 'Avery Q!' where user_id = %L$s$, a), '23514');
  perform pg_temp.deny('profiles: drivers under 17 rejected', a,
    format($s$update profiles set birth_year = extract(year from now())::int - 12 where user_id = %L$s$, a), '23514');

  ---------------------------------------------------------------- garage
  insert into cars (id, owner_id, year, make, model, trim) values
    (car_a::uuid,  a::uuid, 2016, 'Mazda', 'MX-5 Miata', 'Club'),
    (car_a2::uuid, a::uuid, 1994, 'Acura', 'Integra', 'GS-R'),
    (car_b::uuid,  b::uuid, 2015, 'Volkswagen', 'Golf R', 'Base'),
    (car_c::uuid,  c::uuid, 2013, 'Scion', 'FR-S', 'Base');
  insert into car_photos (car_id, path) values
    (car_a::uuid, a || '/miata.jpg'), (car_b::uuid, b || '/golf.jpg'), (car_c::uuid, c || '/frs.jpg');

  perform pg_temp.allow('cars: owner adds a car', a,
    format($s$insert into cars (owner_id, year, make, model) values (%L, 2008, 'Honda', 'Fit')$s$, a));
  perform pg_temp.deny('cars: cannot add a car for someone else', a,
    format($s$insert into cars (owner_id, year, make, model) values (%L, 2008, 'Honda', 'Fit')$s$, b));
  perform pg_temp.allow('cars: readable by anyone who can read the owner', b,
    format($s$select 1 from cars where id = %L$s$, car_a));
  perform pg_temp.deny('cars: non-owner cannot update', b,
    format($s$update cars set nickname = 'mine now' where id = %L$s$, car_a));
  perform pg_temp.deny('cars: non-owner cannot delete', b,
    format($s$delete from cars where id = %L$s$, car_a));
  perform pg_temp.allow('profiles: owner sets primary car to own car', a,
    format($s$update profiles set primary_car_id = %L where user_id = %L$s$, car_a, a));
  perform pg_temp.deny('profiles: primary car must be own car', a,
    format($s$update profiles set primary_car_id = %L where user_id = %L$s$, car_b, a));
  perform pg_temp.allow('car_photos: readable as cars', b,
    format($s$select 1 from car_photos where car_id = %L$s$, car_a));
  perform pg_temp.allow('car_photos: owner adds photo', a,
    format($s$insert into car_photos (car_id, path) values (%L, %L)$s$, car_a, a || '/rear.jpg'));
  perform pg_temp.deny('car_photos: cannot add photo to another''s car', b,
    format($s$insert into car_photos (car_id, path) values (%L, %L)$s$, car_a, b || '/x.jpg'));
  perform pg_temp.allow('build_entries: owner logs a build entry', a,
    format($s$insert into build_entries (car_id, title) values (%L, 'Flyin Miata coilovers')$s$, car_a));
  perform pg_temp.deny('build_entries: cannot log on another''s car', b,
    format($s$insert into build_entries (car_id, title) values (%L, 'nope')$s$, car_a));

  ---------------------------------------------------------------- friendships
  perform pg_temp.deny('friendships: cannot request on behalf of someone else', a,
    format($s$insert into friendships (requester_id, addressee_id) values (%L, %L)$s$, b, a));
  perform pg_temp.deny('friendships: cannot insert as already accepted', a,
    format($s$insert into friendships (requester_id, addressee_id, status) values (%L, %L, 'accepted')$s$, a, c));
  perform pg_temp.allow('friendships: user sends a request', a,
    format($s$insert into friendships (requester_id, addressee_id) values (%L, %L)$s$, a, b), true);
  perform pg_temp.allow('friendships: requester reads the request', a,
    format($s$select 1 from friendships where requester_id = %L$s$, a));
  perform pg_temp.allow('friendships: addressee reads the request', b,
    format($s$select 1 from friendships where requester_id = %L$s$, a));
  perform pg_temp.deny('friendships: third party cannot read', c,
    format($s$select 1 from friendships where requester_id = %L$s$, a));
  perform pg_temp.deny('friendships: requester cannot accept own request', a,
    format($s$update friendships set status = 'accepted' where requester_id = %L and addressee_id = %L$s$, a, b));

  ---------------------------------------------------------------- meets (before friendship accepted)
  insert into meets (id, host_id, title, kind, geom, place_name, starts_at, ends_at, visibility, team_id) values
    (meet_pub::uuid, a::uuid, 'Check: public meet', 'meet',
     st_setsrid(st_makepoint(-75.02, 39.94), 4326)::geography, 'Cherry Hill', now() + interval '1 day', now() + interval '1 day 2 hours', 'public', null),
    (meet_fr::uuid, a::uuid, 'Check: friends meet', 'hangout',
     st_setsrid(st_makepoint(-75.03, 39.93), 4326)::geography, 'Collingswood', now() + interval '2 days', now() + interval '2 days 2 hours', 'friends', null);

  perform pg_temp.allow('meets: public meet readable by signed-in users', b,
    format($s$select 1 from meets where id = %L$s$, meet_pub));
  perform pg_temp.deny('meets: friends meet hidden from non-friends', b,
    format($s$select 1 from meets where id = %L$s$, meet_fr));
  perform pg_temp.deny('meets: insert only through gateway', a,
    format($s$insert into meets (host_id, title, geom, starts_at, ends_at) values (%L, 'x',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography, now(), now() + interval '1 hour')$s$, a));
  perform pg_temp.deny('meets: update only through gateway', a,
    format($s$update meets set title = 'renamed' where id = %L$s$, meet_pub));
  perform pg_temp.allow('meets_in_bbox: returns visible upcoming meets', b,
    $s$select 1 from meets_in_bbox(-75.1, 39.9, -75.0, 40.0) where title = 'Check: public meet'$s$);
  perform pg_temp.deny('meets_in_bbox: hides friends meet from non-friends', b,
    $s$select 1 from meets_in_bbox(-75.1, 39.9, -75.0, 40.0) where title = 'Check: friends meet'$s$);

  perform pg_temp.allow('friendships: addressee accepts', b,
    format($s$update friendships set status = 'accepted' where requester_id = %L and addressee_id = %L$s$, a, b), true);
  perform pg_temp.allow('meets: friends meet readable once friends', b,
    format($s$select 1 from meets where id = %L$s$, meet_fr));

  perform pg_temp.allow('meet_rsvps: user RSVPs to a visible meet', b,
    format($s$insert into meet_rsvps (meet_id, user_id, car_id) values (%L, %L, %L)$s$, meet_pub, b, car_b), true);
  perform pg_temp.allow('meet_rsvps: host reads RSVPs', a,
    format($s$select 1 from meet_rsvps where meet_id = %L and user_id = %L$s$, meet_pub, b));
  perform pg_temp.deny('meet_rsvps: cannot RSVP as someone else', b,
    format($s$insert into meet_rsvps (meet_id, user_id) values (%L, %L)$s$, meet_fr, a));
  perform pg_temp.deny('meet_rsvps: cannot RSVP with another''s car', b,
    format($s$insert into meet_rsvps (meet_id, user_id, car_id) values (%L, %L, %L)$s$, meet_fr, b, car_a));
  perform pg_temp.deny('meet_rsvps: cannot change another''s RSVP', a,
    format($s$update meet_rsvps set status = 'maybe' where user_id = %L$s$, b));

  ---------------------------------------------------------------- privacy, presence, devices
  perform pg_temp.allow('privacy_settings: owner reads own', a,
    format($s$select 1 from privacy_settings where user_id = %L$s$, a));
  perform pg_temp.deny('privacy_settings: others cannot read', b,
    format($s$select 1 from privacy_settings where user_id = %L$s$, a));
  perform pg_temp.deny('privacy_settings: owner cannot write directly', a,
    format($s$update privacy_settings set friends_level = 'hidden' where user_id = %L$s$, a));
  perform pg_temp.allow('privacy_settings: service role writes', 'service',
    format($s$update privacy_settings set ghost_until = now() + interval '1 hour' where user_id = %L$s$, a));
  perform pg_temp.deny('privacy_settings: nearby can never be precise', 'service',
    format($s$update privacy_settings set nearby_level = 'precise' where user_id = %L$s$, a), '23514');

  perform pg_temp.deny('user_presence_cell: users cannot write', a,
    format($s$insert into user_presence_cell (user_id, h3_r7) values (%L, 608819013451759615)$s$, a));
  perform pg_temp.deny('user_presence_cell: users cannot read', a,
    $s$select 1 from user_presence_cell$s$);
  perform pg_temp.allow('user_presence_cell: service role writes', 'service',
    format($s$insert into user_presence_cell (user_id, h3_r7) values (%L, 608819013451759615)$s$, a));

  perform pg_temp.allow('device_tokens: owner registers a token', a,
    format($s$insert into device_tokens (user_id, apns_token, environment) values (%L, 'a1b2c3d4', 'sandbox')$s$, a), true);
  perform pg_temp.deny('device_tokens: cannot register for someone else', a,
    format($s$insert into device_tokens (user_id, apns_token) values (%L, 'ffff')$s$, b));
  perform pg_temp.deny('device_tokens: others cannot read', b,
    format($s$select 1 from device_tokens where user_id = %L$s$, a));
  perform pg_temp.deny('device_tokens: others cannot delete', b,
    format($s$delete from device_tokens where user_id = %L$s$, a));
  perform pg_temp.allow('device_tokens: service role reads', 'service',
    format($s$select 1 from device_tokens where user_id = %L$s$, a));
  perform pg_temp.allow('device_tokens: owner deletes own token', a,
    $s$delete from device_tokens where apns_token = 'a1b2c3d4'$s$);

  ---------------------------------------------------------------- map content
  insert into reports (author_id, kind, geom, note) values
    (a::uuid, 'police', st_setsrid(st_makepoint(-75.01, 39.95), 4326)::geography, 'Check: police'),
    (a::uuid, 'speed_bump', st_setsrid(st_makepoint(-75.015, 39.951), 4326)::geography, 'Check: bump');
  perform pg_temp.truth('reports: police lifetime is 45 minutes, speed bumps permanent',
    exists (select 1 from reports where note = 'Check: police' and not permanent
            and expires_at between now() + interval '44 minutes' and now() + interval '46 minutes')
    and exists (select 1 from reports where note = 'Check: bump' and permanent and expires_at is null));
  perform pg_temp.allow('reports: readable by signed-in users', b,
    $s$select 1 from reports where note = 'Check: police'$s$);
  perform pg_temp.deny('reports: anon cannot read', 'anon', $s$select 1 from reports$s$);
  perform pg_temp.deny('reports: insert only through gateway', a,
    format($s$insert into reports (author_id, kind, geom) values (%L, 'hazard',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography)$s$, a));
  perform pg_temp.deny('reports: confirm only through gateway', b,
    $s$update reports set confirmations = confirmations + 1 where note = 'Check: police'$s$);
  perform pg_temp.deny('reports: dismiss only through gateway', a,
    $s$delete from reports where note = 'Check: police'$s$);
  perform pg_temp.deny('report_votes: service role only', b,
    $s$insert into report_votes (report_id, user_id, still_there)
       select id, auth.uid(), true from reports where note = 'Check: police'$s$);
  perform pg_temp.allow('reports_in_bbox: returns live reports', b,
    $s$select 1 from reports_in_bbox(-75.05, 39.9, -74.95, 40.0) where note = 'Check: police'$s$);
  perform pg_temp.deny('reports_in_bbox: not callable by anon', 'anon',
    $s$select 1 from reports_in_bbox(-75.05, 39.9, -74.95, 40.0)$s$);
  perform pg_temp.allow('hazards_along: finds reports near a route', b,
    $s$select 1 from hazards_along('SRID=4326;LINESTRING(-75.02 39.95, -75.00 39.95)', 100) where note = 'Check: police'$s$);

  perform pg_temp.allow('venue_notes: signed-in user adds a note', b,
    format($s$insert into venue_notes (geom, author_id, entrance) values
      (st_setsrid(st_makepoint(-75.02, 39.94), 4326)::geography, %L, 'steep')$s$, b), true);
  perform pg_temp.deny('venue_notes: cannot add as someone else', b,
    format($s$insert into venue_notes (geom, author_id) values
      (st_setsrid(st_makepoint(-75.02, 39.94), 4326)::geography, %L)$s$, a));
  perform pg_temp.allow('venue_notes_near: returns nearby notes', a,
    $s$select 1 from venue_notes_near(-75.02, 39.94, 200)$s$);

  perform pg_temp.allow('roads: owner adds a road', a,
    format($s$insert into roads (id, author_id, name, path) values ('cccccccc-0000-4000-8007-00000000000a', %L, 'Check road',
      st_geogfromtext('SRID=4326;LINESTRING(-74.80 39.99, -74.82 39.98)'))$s$, a), true);
  perform pg_temp.truth('roads: length_m computed from path',
    (select length_m between 1500 and 2500 from roads where id = 'cccccccc-0000-4000-8007-00000000000a'));
  perform pg_temp.deny('roads: cannot add as someone else', a,
    format($s$insert into roads (author_id, name, path) values (%L, 'x',
      st_geogfromtext('SRID=4326;LINESTRING(-74.80 39.99, -74.82 39.98)'))$s$, b));
  perform pg_temp.allow('roads: readable by signed-in users', b,
    $s$select 1 from roads_in_bbox(-74.9, 39.9, -74.7, 40.1) where name = 'Check road'$s$);
  perform pg_temp.allow('road_ratings: user rates a road', b,
    $s$insert into road_ratings (road_id, user_id, surface, scenery, traffic)
       values ('cccccccc-0000-4000-8007-00000000000a', auth.uid(), 4, 3, 5)$s$);
  perform pg_temp.deny('road_ratings: cannot rate as someone else', b,
    format($s$insert into road_ratings (road_id, user_id, surface, scenery, traffic)
       values ('cccccccc-0000-4000-8007-00000000000a', %L, 4, 3, 5)$s$, a));
  perform pg_temp.deny('road_ratings: scores are 1 to 5', b,
    $s$insert into road_ratings (road_id, user_id, surface, scenery, traffic)
       values ('cccccccc-0000-4000-8007-00000000000a', auth.uid(), 6, 3, 5)$s$, '23514');

  perform pg_temp.allow('spots: owner logs a spot', a,
    format($s$insert into spots (spotter_id, year, make, model, city) values (%L, 1997, 'Toyota', 'Supra', 'Philadelphia')$s$, a), true);
  perform pg_temp.deny('spots: cannot log as someone else', a,
    format($s$insert into spots (spotter_id, make, model) values (%L, 'Toyota', 'Supra')$s$, b));
  perform pg_temp.allow('spots: readable by signed-in users', b,
    $s$select 1 from spots where model = 'Supra' and city = 'Philadelphia'$s$);

  ---------------------------------------------------------------- teams
  perform pg_temp.allow('teams: user creates a team as owner', a,
    format($s$insert into teams (id, owner_id, name, tag, is_public, invite_code)
      values (%L, %L, 'Check Private Crew', 'CPC', false, 'chkprivate1')$s$, team_p, a), true);
  perform pg_temp.allow('teams: user creates a public team', a,
    format($s$insert into teams (id, owner_id, name, tag, is_public)
      values (%L, %L, 'Check Open Crew', 'COC', true)$s$, team_o, a), true);
  perform pg_temp.deny('teams: cannot create a team owned by someone else', b,
    format($s$insert into teams (owner_id, name, tag) values (%L, 'x', 'XYZ')$s$, a));
  perform pg_temp.deny('teams: tag must be 2-5 capitals', a,
    format($s$insert into teams (owner_id, name, tag) values (%L, 'x', 'abc')$s$, a), '23514');
  perform pg_temp.truth('teams: new team gets Owner (all) and Member (none) roles',
    (select count(*) = 2 from team_roles where team_id = team_p::uuid
       and ((name = 'Owner' and permissions = 63) or (name = 'Member' and permissions = 0))));
  perform pg_temp.truth('teams: new team gets general (text) and Garage (voice) channels',
    (select count(*) = 2 from channels where team_id = team_p::uuid
       and ((name = 'general' and kind = 'text') or (name = 'Garage' and kind = 'voice'))));
  perform pg_temp.truth('teams: owner is a member with the Owner role',
    exists (select 1 from team_members m join team_roles r on r.id = m.role_id
            where m.team_id = team_p::uuid and m.user_id = a::uuid and r.name = 'Owner'));

  insert into meets (id, host_id, title, kind, geom, starts_at, ends_at, visibility, team_id) values
    (meet_tm::uuid, a::uuid, 'Check: team meet', 'meet', st_setsrid(st_makepoint(-75.04, 39.92), 4326)::geography,
     now() + interval '3 days', now() + interval '3 days 2 hours', 'team', team_p::uuid);

  perform pg_temp.deny('teams: private team hidden from non-members', b,
    format($s$select 1 from teams where id = %L$s$, team_p));
  perform pg_temp.allow('teams: public team readable by anyone signed in', b,
    format($s$select 1 from teams where id = %L$s$, team_o));
  perform pg_temp.deny('meets: team meet hidden from non-members', b,
    format($s$select 1 from meets where id = %L$s$, meet_tm));
  perform pg_temp.deny('meet_rsvps: cannot RSVP to a meet you cannot see', b,
    format($s$insert into meet_rsvps (meet_id, user_id) values (%L, %L)$s$, meet_tm, b));
  perform pg_temp.deny('team_members: cannot self-join a private team', b,
    format($s$insert into team_members (team_id, user_id) values (%L, %L)$s$, team_p, b));
  perform pg_temp.allow('team_members: can self-join a public team', b,
    format($s$insert into team_members (team_id, user_id) values (%L, %L)$s$, team_o, b));
  perform pg_temp.deny('team_members: self-join cannot pick a privileged role', b,
    format($s$insert into team_members (team_id, user_id, role_id)
      select %L, %L, id from team_roles where team_id = %L and name = 'Owner'$s$, team_o, b, team_o));
  perform pg_temp.deny('team_members: cannot add someone else', b,
    format($s$insert into team_members (team_id, user_id) values (%L, %L)$s$, team_o, c));
  perform pg_temp.deny('join_team: wrong invite code refused', b,
    $s$select join_team('not-a-code')$s$, 'P0002');
  perform pg_temp.allow('join_team: valid invite code joins a private team', b,
    $s$select join_team('chkprivate1')$s$, true);
  perform pg_temp.allow('teams: members read their private team', b,
    format($s$select 1 from teams where id = %L$s$, team_p));
  perform pg_temp.allow('team_roles: members read roles', b,
    format($s$select 1 from team_roles where team_id = %L$s$, team_p));
  perform pg_temp.deny('team_roles: non-members cannot read roles', c,
    format($s$select 1 from team_roles where team_id = %L$s$, team_p));
  perform pg_temp.allow('team_members: members read the roster', b,
    format($s$select 1 from team_members where team_id = %L and user_id = %L$s$, team_p, a));
  perform pg_temp.allow('meets: team meet readable by members', b,
    format($s$select 1 from meets where id = %L$s$, meet_tm));
  perform pg_temp.deny('teams: member without manage_team cannot edit', b,
    format($s$update teams set about = 'taken over' where id = %L$s$, team_p));
  perform pg_temp.allow('teams: owner edits team', a,
    format($s$update teams set about = 'Check crew' where id = %L$s$, team_p));
  perform pg_temp.deny('teams: owner cannot be reassigned by update', a,
    format($s$update teams set owner_id = %L where id = %L$s$, b, team_p));
  perform pg_temp.deny('team_roles: member without manage_roles cannot edit roles', b,
    format($s$update team_roles set permissions = 63 where team_id = %L$s$, team_p));
  perform pg_temp.deny('team_members: member cannot promote self', b,
    format($s$update team_members set role_id = (select id from team_roles where team_id = %L and name = 'Owner')
      where team_id = %L and user_id = %L$s$, team_p, team_p, b));
  perform pg_temp.allow('team_roles: owner (manage_roles) adds a role', a,
    format($s$insert into team_roles (team_id, name, permissions) values (%L, 'Moderator', 16)$s$, team_p));
  perform pg_temp.allow('channels: members read channels', b,
    format($s$select 1 from channels where team_id = %L$s$, team_p));
  perform pg_temp.deny('channels: non-members cannot read channels', c,
    format($s$select 1 from channels where team_id = %L$s$, team_p));
  perform pg_temp.deny('channels: member without manage_channels cannot create', b,
    format($s$insert into channels (team_id, name) values (%L, 'off-topic')$s$, team_p));
  perform pg_temp.allow('channels: owner (manage_channels) creates', a,
    format($s$insert into channels (team_id, name) values (%L, 'off-topic')$s$, team_p));
  perform pg_temp.deny('channels: text channel names are lowercase-hyphen', a,
    format($s$insert into channels (team_id, name) values (%L, 'Off Topic')$s$, team_p), '23514');
  perform pg_temp.deny('team_members: member cannot kick others', b,
    format($s$delete from team_members where team_id = %L and user_id <> %L$s$, team_p, b));
  perform pg_temp.deny('team_members: owner cannot be removed', a,
    format($s$delete from team_members where team_id = %L and user_id = %L$s$, team_p, a));
  perform pg_temp.allow('team_members: owner (kick) removes a member', a,
    format($s$delete from team_members where team_id = %L and user_id = %L$s$, team_p, b));
  perform pg_temp.allow('team_members: member leaves', b,
    format($s$delete from team_members where team_id = %L and user_id = %L$s$, team_p, b));

  ---------------------------------------------------------------- messages
  select id into general_p from channels where team_id = team_p::uuid and name = 'general';

  perform pg_temp.allow('messages: member posts in a channel', b,
    format($s$insert into messages (channel_id, author_id, body) values (%L, %L, 'Check message from Blake')$s$, general_p, b), true);
  select id into msg_b from messages where body = 'Check message from Blake';
  perform pg_temp.allow('messages: members read channel messages', a,
    format($s$select 1 from messages where id = %s$s$, msg_b));
  perform pg_temp.deny('messages: non-members cannot read channel messages', c,
    format($s$select 1 from messages where id = %s$s$, msg_b));
  perform pg_temp.deny('messages: non-members cannot post in a channel', c,
    format($s$insert into messages (channel_id, author_id, body) values (%L, %L, 'hi')$s$, general_p, c));
  perform pg_temp.deny('messages: cannot post as someone else', b,
    format($s$insert into messages (channel_id, author_id, body) values (%L, %L, 'hi')$s$, general_p, a));
  perform pg_temp.deny('messages: body cannot be edited', b,
    format($s$update messages set body = 'edited' where id = %s$s$, msg_b));
  perform pg_temp.allow('messages: author soft-deletes own message', b,
    format($s$update messages set deleted_at = now() where id = %s$s$, msg_b));
  perform pg_temp.deny('messages: non-member cannot soft-delete', c,
    format($s$update messages set deleted_at = now() where id = %s$s$, msg_b));
  perform pg_temp.allow('messages: delete_messages role soft-deletes others', a,
    format($s$update messages set deleted_at = now() where id = %s$s$, msg_b), true);
  perform pg_temp.truth('messages: soft delete clears body and attachment',
    (select body = '' and attachment_path is null and deleted_at is not null from messages where id = msg_b));
  perform pg_temp.truth('messages: in the supabase_realtime publication',
    exists (select 1 from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages'));

  perform pg_temp.allow('read_markers: owner writes own marker', a,
    format($s$insert into read_markers (user_id, channel_id, last_read_message_id) values (%L, %L, %s)$s$, a, general_p, msg_b));
  perform pg_temp.deny('read_markers: cannot write for someone else', a,
    format($s$insert into read_markers (user_id, channel_id, last_read_message_id) values (%L, %L, %s)$s$, b, general_p, msg_b));

  ---------------------------------------------------------------- blocks
  perform pg_temp.deny('blocks: cannot block on behalf of someone else', a,
    format($s$insert into blocks (blocker_id, blocked_id) values (%L, %L)$s$, b, c));
  perform pg_temp.allow('blocks: user blocks someone', a,
    format($s$insert into blocks (blocker_id, blocked_id) values (%L, %L)$s$, a, c), true);
  perform pg_temp.allow('blocks: owner reads own blocks', a,
    $s$select 1 from blocks$s$);
  perform pg_temp.deny('blocks: others cannot read', b,
    format($s$select 1 from blocks where blocker_id = %L$s$, a));
  perform pg_temp.deny('blocks: blocked user cannot see blocker''s block row', c,
    $s$select 1 from blocks$s$);
  perform pg_temp.deny('profiles: hidden from users the owner blocked', c,
    format($s$select 1 from profiles where user_id = %L$s$, a));
  perform pg_temp.deny('cars: hidden from users the owner blocked', c,
    format($s$select 1 from cars where id = %L$s$, car_a));
  perform pg_temp.deny('meets: hidden across a block', c,
    format($s$select 1 from meets where id = %L$s$, meet_pub));

  ---------------------------------------------------------------- threads
  perform pg_temp.allow('threads: party opens a DM', a,
    format($s$insert into threads (id, kind, a_id, b_id) values (%L, 'dm', %L, %L)$s$, thr_ab, a, b), true);
  perform pg_temp.allow('threads: other party reads the DM', b,
    format($s$select 1 from threads where id = %L$s$, thr_ab));
  perform pg_temp.deny('threads: outsiders cannot read', c,
    format($s$select 1 from threads where id = %L$s$, thr_ab));
  perform pg_temp.deny('threads: cannot open a thread between two other people', a,
    format($s$insert into threads (kind, a_id, b_id) values ('dm', %L, %L)$s$, b, c));
  perform pg_temp.deny('threads: cannot open a DM across a block', c,
    format($s$insert into threads (kind, a_id, b_id) values ('dm', %L, %L)$s$, c, a));
  perform pg_temp.deny('threads: one DM per pair', b,
    format($s$insert into threads (kind, a_id, b_id) values ('dm', %L, %L)$s$, b, a), '23505');
  perform pg_temp.allow('messages: thread party sends a DM', b,
    format($s$insert into messages (thread_id, author_id, body) values (%L, %L, 'See you at the meet')$s$, thr_ab, b), true);
  perform pg_temp.allow('messages: thread parties read DMs', a,
    format($s$select 1 from messages where thread_id = %L$s$, thr_ab));
  perform pg_temp.deny('messages: outsiders cannot read DMs', c,
    format($s$select 1 from messages where thread_id = %L$s$, thr_ab));
  perform pg_temp.deny('messages: outsiders cannot post into a DM', c,
    format($s$insert into messages (thread_id, author_id, body) values (%L, %L, 'hi')$s$, thr_ab, c));

  ---------------------------------------------------------------- feed
  perform pg_temp.allow('posts: owner posts a clip', a,
    format($s$insert into posts (id, author_id, car_id, video_path, caption, duration_ms)
      values (%L, %L, %L, %L, 'Golden hour on 206', 18000)$s$, post_a, a, car_a, a || '/clip.mp4'), true);
  perform pg_temp.deny('posts: users cannot seed like_count', a,
    format($s$insert into posts (author_id, video_path, like_count) values (%L, 'x.mp4', 500)$s$, a));
  perform pg_temp.truth('posts: like_count stays server-owned',
    (select like_count = 0 from posts where id = post_a::uuid));
  perform pg_temp.deny('posts: cannot post as someone else', b,
    format($s$insert into posts (author_id, video_path) values (%L, 'x.mp4')$s$, a));
  perform pg_temp.deny('posts: cannot tag another''s car', b,
    format($s$insert into posts (author_id, car_id, video_path) values (%L, %L, 'x.mp4')$s$, b, car_a));
  perform pg_temp.allow('posts: readable by signed-in users', b,
    format($s$select 1 from posts where id = %L$s$, post_a));
  perform pg_temp.deny('posts: hidden across a block', c,
    format($s$select 1 from posts where id = %L$s$, post_a));
  perform pg_temp.deny('posts: non-owner cannot delete', b,
    format($s$delete from posts where id = %L$s$, post_a));
  perform pg_temp.deny('posts: captions cannot be edited', a,
    format($s$update posts set caption = 'edited' where id = %L$s$, post_a));

  perform pg_temp.allow('post_likes: user likes a post', b,
    format($s$insert into post_likes (post_id, user_id) values (%L, %L)$s$, post_a, b), true);
  perform pg_temp.truth('post_likes: trigger increments like_count',
    (select like_count = 1 from posts where id = post_a::uuid));
  perform pg_temp.deny('post_likes: cannot like as someone else', b,
    format($s$insert into post_likes (post_id, user_id) values (%L, %L)$s$, post_a, a));
  perform pg_temp.deny('post_likes: cannot like a post hidden by a block', c,
    format($s$insert into post_likes (post_id, user_id) values (%L, %L)$s$, post_a, c));
  perform pg_temp.deny('post_likes: likes are private to the liker', a,
    format($s$select 1 from post_likes where user_id = %L$s$, b));
  perform pg_temp.allow('post_likes: user unlikes', b,
    format($s$delete from post_likes where post_id = %L and user_id = %L$s$, post_a, b), true);
  perform pg_temp.truth('post_likes: trigger decrements like_count',
    (select like_count = 0 from posts where id = post_a::uuid));

  perform pg_temp.allow('post_comments: user comments', b,
    format($s$insert into post_comments (id, post_id, author_id, body)
      values ('cccccccc-0000-4000-8008-00000000000b', %L, %L, 'That light is unreal')$s$, post_a, b), true);
  perform pg_temp.truth('post_comments: trigger maintains comment_count',
    (select comment_count = 1 from posts where id = post_a::uuid));
  perform pg_temp.deny('post_comments: cannot comment as someone else', b,
    format($s$insert into post_comments (post_id, author_id, body) values (%L, %L, 'x')$s$, post_a, a));
  perform pg_temp.deny('post_comments: third party cannot delete a comment', c,
    $s$delete from post_comments where id = 'cccccccc-0000-4000-8008-00000000000b'$s$);
  perform pg_temp.allow('post_comments: post owner deletes a comment', a,
    $s$delete from post_comments where id = 'cccccccc-0000-4000-8008-00000000000b'$s$);
  perform pg_temp.allow('post_comments: author deletes own comment', b,
    $s$delete from post_comments where id = 'cccccccc-0000-4000-8008-00000000000b'$s$);

  perform pg_temp.allow('follows: user follows someone', b,
    format($s$insert into follows (follower_id, followee_id) values (%L, %L)$s$, b, a), true);
  perform pg_temp.deny('follows: cannot follow on behalf of someone else', b,
    format($s$insert into follows (follower_id, followee_id) values (%L, %L)$s$, a, b));
  perform pg_temp.deny('follows: owner only', a,
    format($s$select 1 from follows where follower_id = %L$s$, b));
  perform pg_temp.deny('follows: cannot follow across a block', c,
    format($s$insert into follows (follower_id, followee_id) values (%L, %L)$s$, c, a));

  ---------------------------------------------------------------- showdown
  perform pg_temp.allow('showdown_entries: owner enters a car with a photo', a,
    format($s$insert into showdown_entries (car_id, class, rating) values (%L, 'street', 2400)$s$, car_a), true);
  perform pg_temp.truth('showdown_entries: users cannot seed rating',
    (select rating = 1200 from showdown_entries where car_id = car_a::uuid));
  perform pg_temp.deny('showdown_entries: car needs at least one photo', a,
    format($s$insert into showdown_entries (car_id) values (%L)$s$, car_a2));
  perform pg_temp.deny('showdown_entries: cannot enter another''s car', a,
    format($s$insert into showdown_entries (car_id) values (%L)$s$, car_b));
  perform pg_temp.allow('showdown_entries: readable by signed-in users', b,
    format($s$select 1 from showdown_entries where car_id = %L$s$, car_a));
  perform pg_temp.deny('showdown_entries: rating not writable directly', a,
    format($s$update showdown_entries set rating = 3000 where car_id = %L$s$, car_a));
  insert into showdown_entries (car_id) values (car_b::uuid), (car_c::uuid);

  perform pg_temp.deny('showdown_votes: no direct inserts', a,
    format($s$insert into showdown_votes (voter_id, winner_car_id, loser_car_id) values (%L, %L, %L)$s$, a, car_b, car_c));
  perform pg_temp.deny('cast_showdown_vote: rejects voting on own car', a,
    format($s$select * from cast_showdown_vote(%L, %L)$s$, car_a, car_b));
  perform pg_temp.allow('cast_showdown_vote: records a vote', a,
    format($s$select * from cast_showdown_vote(%L, %L)$s$, car_b, car_c), true);
  perform pg_temp.truth('cast_showdown_vote: Elo K=24 moves equal ratings by 12',
    (select rating = 1212 and wins = 1 from showdown_entries where car_id = car_b::uuid)
    and (select rating = 1188 and losses = 1 from showdown_entries where car_id = car_c::uuid));
  perform pg_temp.deny('cast_showdown_vote: rejects a repeat pair', a,
    format($s$select * from cast_showdown_vote(%L, %L)$s$, car_c, car_b), '23505');
  perform pg_temp.allow('showdown_votes: voter reads own votes', a,
    $s$select 1 from showdown_votes$s$);
  perform pg_temp.deny('showdown_votes: others cannot read', b,
    $s$select 1 from showdown_votes$s$);

  ---------------------------------------------------------------- market
  perform pg_temp.allow('listings: seller lists a part', a,
    format($s$insert into listings (id, seller_id, kind, title, price_cents, condition)
      values (%L, %L, 'part', 'NB Miata hardtop', 90000, 'used')$s$, lst_a, a), true);
  perform pg_temp.deny('listings: cannot list as someone else', b,
    format($s$insert into listings (seller_id, kind, title, price_cents, condition) values (%L, 'part', 'x', 1, 'new')$s$, a));
  perform pg_temp.allow('listings: readable by signed-in users', b,
    format($s$select 1 from listings where id = %L$s$, lst_a));
  perform pg_temp.deny('listings: non-seller cannot edit', b,
    format($s$update listings set price_cents = 1 where id = %L$s$, lst_a));
  perform pg_temp.allow('listings: seller marks sold', a,
    format($s$update listings set status = 'sold' where id = %L$s$, lst_a));
  perform pg_temp.allow('listing_photos: seller adds photos', a,
    format($s$insert into listing_photos (listing_id, path) values (%L, %L)$s$, lst_a, a || '/top.jpg'));
  perform pg_temp.deny('listing_photos: non-seller cannot add photos', b,
    format($s$insert into listing_photos (listing_id, path) values (%L, %L)$s$, lst_a, b || '/x.jpg'));
  perform pg_temp.allow('listing_saves: user saves a listing', b,
    format($s$insert into listing_saves (listing_id, user_id) values (%L, %L)$s$, lst_a, b), true);
  perform pg_temp.deny('listing_saves: owner only', a,
    format($s$select 1 from listing_saves where user_id = %L$s$, b));
  perform pg_temp.allow('threads: buyer opens a listing thread with the seller', b,
    format($s$insert into threads (kind, listing_id, a_id, b_id) values ('listing', %L, %L, %L)$s$, lst_a, b, a));
  perform pg_temp.deny('threads: listing thread must include the seller', b,
    format($s$insert into threads (kind, listing_id, a_id, b_id) values ('listing', %L, %L, %L)$s$, lst_a, b, c));

  ---------------------------------------------------------------- progress, safety
  insert into achievements (user_id, key) values (a::uuid, 'first_meet');
  perform pg_temp.allow('achievements: readable by anyone, even signed out', 'anon',
    $s$select 1 from achievements where key = 'first_meet'$s$);
  perform pg_temp.deny('achievements: users cannot award themselves', a,
    format($s$insert into achievements (user_id, key) values (%L, 'convoy_leader')$s$, a));

  perform pg_temp.allow('content_reports: user files a report', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason) values (%L, 'post', %L, 'spam')$s$, b, post_a), true);
  perform pg_temp.deny('content_reports: cannot file as someone else', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason) values (%L, 'post', 'x', 'spam')$s$, a));
  perform pg_temp.allow('content_reports: reporter reads own report', b,
    format($s$select 1 from content_reports where reporter_id = %L$s$, b));
  perform pg_temp.deny('content_reports: cannot read others'' reports', a,
    $s$select 1 from content_reports$s$);

  perform pg_temp.allow('race_results: owner saves a run', a,
    format($s$insert into race_results (user_id, car_id, et_ms, trap_mph_x10, reaction_ms)
      values (%L, %L, 15210, 921, 412)$s$, a, car_a), true);
  perform pg_temp.deny('race_results: run must use own car', a,
    format($s$insert into race_results (user_id, car_id, et_ms) values (%L, %L, 13000)$s$, a, car_b));
  perform pg_temp.allow('race_results: readable by signed-in users', b,
    format($s$select 1 from race_results where user_id = %L$s$, a));
  perform pg_temp.deny('race_results: input log capped at 4 KB', a,
    format($s$insert into race_results (user_id, car_id, et_ms, input_log) values (%L, %L, 15000, decode(repeat('00', 5000), 'hex'))$s$, a, car_a), '23514');

  ---------------------------------------------------------------- storage
  perform pg_temp.truth('storage: seven public buckets exist, messages is private',
    (select count(*) = 7 from storage.buckets where public and id in
      ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'catalog'))
    and (select not public from storage.buckets where id = 'messages'));
  perform pg_temp.allow('storage: owner uploads under own folder', a,
    format($s$insert into storage.objects (bucket_id, name) values ('avatars', %L)$s$, a || '/avatar.jpg'), true);
  perform pg_temp.deny('storage: cannot upload into another user''s folder', a,
    format($s$insert into storage.objects (bucket_id, name) values ('cars', %L)$s$, b || '/x.jpg'));
  perform pg_temp.deny('storage: users cannot write the catalog bucket', a,
    format($s$insert into storage.objects (bucket_id, name) values ('catalog', %L)$s$, a || '/manifest.json'));
  perform pg_temp.allow('storage: media is publicly readable', 'anon',
    format($s$select 1 from storage.objects where bucket_id = 'avatars' and name = %L$s$, a || '/avatar.jpg'));
  perform pg_temp.deny('storage: others cannot delete an owner''s file', b,
    format($s$delete from storage.objects where bucket_id = 'avatars' and name = %L$s$, a || '/avatar.jpg'));
  perform pg_temp.allow('storage: owner deletes own file', a,
    format($s$delete from storage.objects where bucket_id = 'avatars' and name = %L$s$, a || '/avatar.jpg'));

  -- ============================================================== since W0-C (W6-B, SEC-1)
  ---------------------------------------------------------------- coverage
  perform pg_temp.truth('rls: enabled on every public table',
    not exists (select 1 from pg_class
                where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity));
  perform pg_temp.truth('suspension: write guard on every RLS table',
    not exists (select 1 from pg_class t
                where t.relnamespace = 'public'::regnamespace and t.relkind = 'r' and t.relrowsecurity
                  and not exists (select 1 from pg_trigger g
                                  where g.tgrelid = t.oid and g.tgname = 'suspended_write_guard')));

  ---------------------------------------------------------------- convoys
  perform pg_temp.allow('convoys: service role mirrors convoy state', 'service',
    $s$insert into convoys (id, join_code, state) values ('chk-convoy', 'CHKJOIN1', '{"member_uids":[]}')$s$, true);
  perform pg_temp.deny('convoys: users cannot read', a, $s$select 1 from convoys$s$);
  perform pg_temp.deny('convoys: users cannot write', a,
    $s$insert into convoys (id, join_code, state) values ('chk-convoy-2', 'CHKJOIN2', '{}')$s$);
  perform pg_temp.deny('convoys: anon cannot read', 'anon', $s$select 1 from convoys$s$);

  ---------------------------------------------------------------- push
  perform pg_temp.allow('notification_prefs: owner saves own', a,
    format($s$insert into notification_prefs (user_id, messages) values (%L, false)$s$, a), true);
  perform pg_temp.allow('notification_prefs: owner reads own', a,
    format($s$select 1 from notification_prefs where user_id = %L$s$, a));
  perform pg_temp.allow('notification_prefs: owner updates own', a,
    format($s$update notification_prefs set messages = true where user_id = %L$s$, a));
  perform pg_temp.deny('notification_prefs: others cannot read', b,
    format($s$select 1 from notification_prefs where user_id = %L$s$, a));
  perform pg_temp.deny('notification_prefs: others cannot update', b,
    format($s$update notification_prefs set messages = false where user_id = %L$s$, a));
  perform pg_temp.deny('notification_prefs: cannot write for someone else', a,
    format($s$insert into notification_prefs (user_id) values (%L)$s$, b));
  perform pg_temp.truth('push: notify triggers on messages and friendships',
    exists (select 1 from pg_trigger where tgname = 'messages_notify' and tgrelid = 'public.messages'::regclass)
    and exists (select 1 from pg_trigger where tgname = 'friendships_notify' and tgrelid = 'public.friendships'::regclass));
  perform pg_temp.deny('notify_gateway: not callable by users', a,
    $s$select public.notify_gateway('{}'::jsonb)$s$);

  ---------------------------------------------------------------- achievements
  perform pg_temp.truth('achievements: a Strip run awards strip_1',
    exists (select 1 from achievements where user_id = a::uuid and key = 'strip_1'));
  perform pg_temp.deny('award: not callable by users', a,
    format($s$select public.award(%L, 'host_3')$s$, a));

  ---------------------------------------------------------------- meet_checkins
  perform pg_temp.allow('meet_checkins: gateway records a check-in', 'service',
    format($s$insert into meet_checkins (meet_id, user_id) values (%L, %L)$s$, meet_pub, b), true);
  perform pg_temp.truth('meet_checkins: a check-in awards first_meet',
    exists (select 1 from achievements where user_id = b::uuid and key = 'first_meet'));
  perform pg_temp.allow('meet_checkins: readable with the meet', a,
    format($s$select 1 from meet_checkins where meet_id = %L$s$, meet_pub));
  perform pg_temp.deny('meet_checkins: hidden across a block', c,
    format($s$select 1 from meet_checkins where meet_id = %L$s$, meet_pub));
  perform pg_temp.deny('meet_checkins: users cannot check in directly', b,
    format($s$insert into meet_checkins (meet_id, user_id) values (%L, %L)$s$, meet_fr, b));

  ---------------------------------------------------------------- recurring meets
  perform pg_temp.allow('meets: gateway sets a weekly series with a destination', 'service',
    format($s$update meets set recurrence = 'weekly', series_id = %L, time_zone = 'America/New_York',
      dest_lat = 39.95, dest_lng = -75.16, dest_name = 'Check: Philly' where id = %L$s$, meet_pub, meet_pub), true);
  perform pg_temp.deny('meets: recurrence is weekly, biweekly, or monthly', 'service',
    format($s$update meets set recurrence = 'daily' where id = %L$s$, meet_pub), '23514');
  perform pg_temp.deny('meets: a recurring meet needs a series id', 'service',
    format($s$update meets set recurrence = 'weekly' where id = %L$s$, meet_fr), '23514');
  perform pg_temp.deny('meets: a destination needs both coordinates', 'service',
    format($s$update meets set dest_lat = 39.9 where id = %L$s$, meet_fr), '23514');
  perform pg_temp.deny('meets: one occurrence per series start', 'service',
    format($s$update meets set series_id = %L, starts_at = m.starts_at, ends_at = m.ends_at
      from (select starts_at, ends_at from meets where id = %L) m where meets.id = %L$s$, meet_pub, meet_pub, meet_fr), '23505');
  perform pg_temp.deny('meets: users cannot set recurrence', a,
    format($s$update meets set recurrence = 'monthly' where id = %L$s$, meet_pub));
  perform pg_temp.allow('meets_in_bbox: returns recurrence and destination', b,
    $s$select 1 from meets_in_bbox(-75.1, 39.9, -75.0, 40.0)
       where title = 'Check: public meet' and recurrence = 'weekly' and dest_name = 'Check: Philly'$s$);

  ---------------------------------------------------------------- listing category and wanted
  perform pg_temp.allow('listings: wanted listing with a part category', b,
    format($s$insert into listings (seller_id, kind, category, title, price_cents, condition)
      values (%L, 'wanted', 'wheels_tires', 'Wanted: 15x8 wheels', 40000, 'used')$s$, b));
  perform pg_temp.deny('listings: category must be a known part category', b,
    format($s$insert into listings (seller_id, kind, category, title, price_cents, condition)
      values (%L, 'part', 'rockets', 'x', 1, 'new')$s$, b), '22P02');

  ---------------------------------------------------------------- notifications
  perform pg_temp.truth('notifications: a like records one row for the post author',
    (select count(*) = 1 from notifications where user_id = a::uuid and kind = 'like' and actor_id = b::uuid));
  insert into post_likes (post_id, user_id) values (post_a::uuid, b::uuid);
  delete from post_likes where post_id = post_a::uuid and user_id = b::uuid;
  perform pg_temp.truth('notifications: liking again does not notify twice',
    (select count(*) = 1 from notifications where user_id = a::uuid and kind = 'like'));
  perform pg_temp.allow('notifications: recipient reads own', a,
    $s$select 1 from notifications where kind = 'like'$s$);
  perform pg_temp.deny('notifications: others cannot read', b,
    format($s$select 1 from notifications where user_id = %L$s$, a));
  perform pg_temp.allow('notifications: recipient marks read', a,
    $s$update notifications set read_at = now() where kind = 'like'$s$);
  perform pg_temp.deny('notifications: recipient cannot rewrite a row', a,
    $s$update notifications set title = 'rewritten' where kind = 'like'$s$);
  perform pg_temp.deny('notifications: users cannot insert', a,
    format($s$insert into notifications (user_id, kind, title) values (%L, 'like', 'x')$s$, a));
  perform pg_temp.deny('notifications: users cannot delete', a,
    $s$delete from notifications$s$);
  perform pg_temp.deny('record_notification: not callable by users', a,
    format($s$select public.record_notification(%L, 'like', null, null, 'x', null, null)$s$, b));

  ---------------------------------------------------------------- help requests
  insert into help_requests (id, requester_id, kind, geom, note) values
    (help_a::uuid, a::uuid, 'flat_tire', st_setsrid(st_makepoint(-75.02, 39.94), 4326)::geography, 'Check: help');
  insert into help_responses (request_id, user_id) values (help_a::uuid, b::uuid);
  perform pg_temp.allow('help_requests: requester reads own', a,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  perform pg_temp.allow('help_requests: friends read an active request', b,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  perform pg_temp.deny('help_requests: hidden across a block', c,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  perform pg_temp.deny('help_requests: anon cannot read', 'anon', $s$select 1 from help_requests$s$);
  perform pg_temp.deny('help_requests: insert only through gateway', a,
    format($s$insert into help_requests (requester_id, kind, geom) values (%L, 'stuck',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography)$s$, a));
  perform pg_temp.deny('help_requests: extend only through gateway', a,
    format($s$update help_requests set expires_at = now() + interval '1 day' where id = %L$s$, help_a));
  perform pg_temp.deny('help_requests: one active request per person', 'service',
    format($s$insert into help_requests (requester_id, kind, geom) values (%L, 'stuck',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography)$s$, a), '23505');
  perform pg_temp.allow('help_responses: requester sees who is coming', a,
    format($s$select 1 from help_responses where request_id = %L$s$, help_a));
  perform pg_temp.allow('help_responses: responder sees own response', b,
    format($s$select 1 from help_responses where request_id = %L$s$, help_a));
  perform pg_temp.deny('help_responses: outsiders cannot read', c,
    format($s$select 1 from help_responses where request_id = %L$s$, help_a));
  perform pg_temp.deny('help_responses: respond only through gateway', c,
    format($s$insert into help_responses (request_id, user_id) values (%L, %L)$s$, help_a, c));
  update help_requests set ended_at = now() where id = help_a::uuid;
  perform pg_temp.deny('help_requests: friends lose an ended request', b,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  perform pg_temp.allow('help_requests: requester still reads an ended request', a,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  update help_requests set ended_at = null where id = help_a::uuid;

  ---------------------------------------------------------------- feed_for_you, showdown_week_top
  perform pg_temp.allow('feed_for_you: returns visible posts', b,
    format($s$select 1 from feed_for_you(0, 50) where id = %L$s$, post_a));
  perform pg_temp.deny('feed_for_you: hides posts across a block', c,
    format($s$select 1 from feed_for_you(0, 50) where id = %L$s$, post_a));
  perform pg_temp.deny('feed_for_you: not callable by anon', 'anon',
    $s$select 1 from feed_for_you(0, 10)$s$);
  perform pg_temp.allow('showdown_week_top: ranks this week''s winners', b,
    format($s$select 1 from showdown_week_top('street') where car_id = %L$s$, car_b));
  perform pg_temp.deny('showdown_week_top: not callable by anon', 'anon',
    $s$select 1 from showdown_week_top('street')$s$);
  perform pg_temp.deny('showdown_close_week: service role only', a,
    $s$select public.showdown_close_week()$s$);

  ---------------------------------------------------------------- moderation: hidden_at
  perform pg_temp.allow('hidden_at: owner update runs', a,
    format($s$update listings set hidden_at = now() where id = %L$s$, lst_a), true);
  perform pg_temp.truth('hidden_at: end users cannot hide or unhide rows',
    (select hidden_at is null from listings where id = lst_a::uuid));
  perform pg_temp.deny('moderation_hide: service role only', a,
    format($s$select moderation_hide('post', %L)$s$, post_a));
  perform pg_temp.allow('moderation_hide: reviewer hides a post', 'service',
    format($s$select moderation_hide('post', %L)$s$, post_a), true);
  perform pg_temp.deny('posts: hidden post disappears for others', b,
    format($s$select 1 from posts where id = %L$s$, post_a));
  perform pg_temp.allow('posts: author still sees own hidden post', a,
    format($s$select 1 from posts where id = %L$s$, post_a));
  perform pg_temp.deny('feed_for_you: hidden posts drop out', b,
    format($s$select 1 from feed_for_you(0, 50) where id = %L$s$, post_a));
  perform pg_temp.deny('post_likes: cannot like a hidden post', b,
    format($s$insert into post_likes (post_id, user_id) values (%L, %L)$s$, post_a, b));
  perform pg_temp.allow('moderation_restore: reviewer restores a post', 'service',
    format($s$select moderation_restore('post', %L)$s$, post_a), true);
  perform pg_temp.allow('posts: restored post readable again', b,
    format($s$select 1 from posts where id = %L$s$, post_a));

  insert into content_reports (reporter_id, target_kind, target_id, reason) values
    (a::uuid, 'listing', lst_a, 'scam'), (b::uuid, 'listing', lst_a, 'scam');
  perform pg_temp.truth('content_reports: two reporters do not hide',
    (select hidden_at is null from listings where id = lst_a::uuid));
  insert into content_reports (reporter_id, target_kind, target_id, reason) values (c::uuid, 'listing', lst_a, 'scam');
  perform pg_temp.truth('content_reports: three reporters in 7 days hide the target',
    (select hidden_at is not null from listings where id = lst_a::uuid));
  perform pg_temp.deny('listings: auto-hidden listing disappears for others', b,
    format($s$select 1 from listings where id = %L$s$, lst_a));
  perform pg_temp.allow('moderation_restore: reviewer restores a listing', 'service',
    format($s$select moderation_restore('listing', %L)$s$, lst_a), true);
  perform pg_temp.truth('moderation_restore: open reports closed',
    not exists (select 1 from content_reports where target_id = lst_a and resolved_at is null));

  perform pg_temp.allow('moderation_hide: reviewer hides a car', 'service',
    format($s$select moderation_hide('car', %L)$s$, car_b), true);
  perform pg_temp.deny('showdown_week_top: hidden cars drop out', b,
    format($s$select 1 from showdown_week_top('street') where car_id = %L$s$, car_b));
  perform pg_temp.allow('moderation_restore: reviewer restores a car', 'service',
    format($s$select moderation_restore('car', %L)$s$, car_b), true);

  ---------------------------------------------------------------- moderation: suspension
  perform pg_temp.deny('moderation_suspend: service role only', a,
    format($s$select moderation_suspend(%L)$s$, c));
  perform pg_temp.allow('moderation_suspend: reviewer suspends an account', 'service',
    format($s$select moderation_suspend(%L)$s$, c), true);
  perform pg_temp.deny('suspension: suspended account cannot insert', c,
    format($s$insert into spots (spotter_id, make, model) values (%L, 'Nissan', 'Silvia')$s$, c), 'PT423');
  perform pg_temp.deny('suspension: suspended account cannot update', c,
    format($s$update profiles set bio = 'still here' where user_id = %L$s$, c), 'PT423');
  perform pg_temp.deny('suspension: suspended account cannot upload', c,
    format($s$insert into storage.objects (bucket_id, name) values ('avatars', %L)$s$, c || '/x.jpg'));
  perform pg_temp.allow('suspension: account still reads its own profile', c,
    format($s$select 1 from profiles where user_id = %L$s$, c));
  perform pg_temp.deny('suspension: profile hidden from others', b,
    format($s$select 1 from profiles where user_id = %L$s$, c));
  perform pg_temp.deny('suspension: cars hidden from others', b,
    format($s$select 1 from cars where id = %L$s$, car_c));
  perform pg_temp.allow('moderation_unsuspend: reviewer lifts it', 'service',
    format($s$select moderation_unsuspend(%L)$s$, c), true);
  perform pg_temp.allow('suspension: lifted suspension shows the profile again', b,
    format($s$select 1 from profiles where user_id = %L$s$, c));

  perform pg_temp.allow('moderation_suspend: suspends the like''s actor', 'service',
    format($s$select moderation_suspend(%L)$s$, b), true);
  perform pg_temp.deny('notifications: rows caused by a suspended account drop out', a,
    $s$select 1 from notifications where kind = 'like'$s$);
  perform pg_temp.deny('help_responses: responses by a suspended account drop out', a,
    format($s$select 1 from help_responses where request_id = %L$s$, help_a));
  perform pg_temp.deny('meet_checkins: check-ins by a suspended account drop out', a,
    format($s$select 1 from meet_checkins where meet_id = %L$s$, meet_pub));
  perform pg_temp.allow('moderation_unsuspend: lifts the actor''s suspension', 'service',
    format($s$select moderation_unsuspend(%L)$s$, b), true);

  perform pg_temp.allow('moderation_suspend: suspends the help requester', 'service',
    format($s$select moderation_suspend(%L)$s$, a), true);
  perform pg_temp.deny('help_requests: a suspended requester''s request drops out', b,
    format($s$select 1 from help_requests where id = %L$s$, help_a));
  perform pg_temp.truth('help_requests: suspending ends active requests',
    (select ended_at is not null from help_requests where id = help_a::uuid));
  perform pg_temp.allow('moderation_unsuspend: lifts the requester''s suspension', 'service',
    format($s$select moderation_unsuspend(%L)$s$, a), true);

  ---------------------------------------------------------------- abuse limits (SAFE-9)
  insert into messages (thread_id, author_id, body)
    select thr_ab::uuid, b::uuid, 'Check burst ' || g from generate_series(1, 5) g;
  perform pg_temp.deny('abuse: 5 messages in 5 seconds', b,
    format($s$insert into messages (thread_id, author_id, body) values (%L, %L, 'one more')$s$, thr_ab, b), 'PT429');
  delete from messages where body like 'Check burst %';

  insert into posts (author_id, video_path)
    select b::uuid, b || '/burst' || g || '.mp4' from generate_series(1, 10) g;
  perform pg_temp.deny('abuse: 10 posts a day', b,
    format($s$insert into posts (author_id, video_path) values (%L, %L)$s$, b, b || '/one-more.mp4'), 'PT429');
  delete from posts where author_id = b::uuid;

  insert into post_comments (post_id, author_id, body)
    select post_a::uuid, b::uuid, 'Check burst ' || g from generate_series(1, 30) g;
  perform pg_temp.deny('abuse: 30 comments an hour', b,
    format($s$insert into post_comments (post_id, author_id, body) values (%L, %L, 'one more')$s$, post_a, b), 'PT429');
  delete from post_comments where body like 'Check burst %';

  insert into listings (seller_id, kind, title, price_cents, condition)
    select b::uuid, 'part', 'Check burst ' || g, 100, 'used' from generate_series(1, 10) g;
  perform pg_temp.deny('abuse: 10 listings a day', b,
    format($s$insert into listings (seller_id, kind, title, price_cents, condition) values (%L, 'part', 'one more', 1, 'new')$s$, b), 'PT429');
  delete from listings where title like 'Check burst %';

  insert into teams (owner_id, name, tag)
    select b::uuid, 'Check burst ' || g, 'CKB' || chr(64 + g) from generate_series(1, 3) g;
  perform pg_temp.deny('abuse: 3 teams a day', b,
    format($s$insert into teams (owner_id, name, tag) values (%L, 'one more', 'CKBZ')$s$, b), 'PT429');
  delete from teams where name like 'Check burst %';

  insert into content_reports (reporter_id, target_kind, target_id, reason)
    select b::uuid, 'check', 'burst-' || g, 'spam' from generate_series(1, 20) g;
  perform pg_temp.deny('abuse: 20 content reports a day', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason) values (%L, 'check', 'one-more', 'spam')$s$, b), 'PT429');
  delete from content_reports where target_kind = 'check';

  perform pg_temp.truth('abuse: 30 friend requests a day enforced by trigger',
    exists (select 1 from pg_trigger where tgname = 'abuse_limit' and tgrelid = 'public.friendships'::regclass));
  perform pg_temp.truth('abuse: help requests a day and map reports in 10 minutes counted in Postgres',
    to_regclass('public.help_requests_requester_created_idx') is not null
    and to_regclass('public.report_votes_user_created_idx') is not null);

  ---------------------------------------------------------------- hardening (W9-H)
  perform pg_temp.deny('is_blocked_pair: says nothing about other people''s blocks', b,
    format($s$select 1 where public.is_blocked_pair(%L, %L)$s$, a, c));
  perform pg_temp.allow('is_blocked_pair: answers for the caller''s own pair', c,
    format($s$select 1 where public.is_blocked_pair(%L, %L)$s$, a, c));
  perform pg_temp.deny('are_friends: says nothing about other people''s friendships', c,
    format($s$select 1 where public.are_friends(%L, %L)$s$, a, b));
  perform pg_temp.allow('are_friends: answers for the caller''s own pair', b,
    format($s$select 1 where public.are_friends(%L, %L)$s$, a, b));
  perform pg_temp.deny('can_read_help: not callable by anon', 'anon',
    format($s$select public.can_read_help(%L)$s$, a));
  perform pg_temp.truth('security definer functions: none callable by anon',
    not exists (select 1 from pg_proc p
                where p.pronamespace = 'public'::regnamespace and p.prosecdef
                  and has_function_privilege('anon', p.oid, 'execute')));

  perform pg_temp.deny('showdown_entries: cannot withdraw another''s car', b,
    format($s$delete from showdown_entries where car_id = %L$s$, car_a));
  perform pg_temp.allow('showdown_entries: owner withdraws own car', a,
    format($s$delete from showdown_entries where car_id = %L$s$, car_a));

  insert into meets (id, host_id, title, kind, geom, starts_at, ends_at, visibility) values
    ('cccccccc-0000-4000-8003-000000000004', a::uuid, 'Check: live meet', 'meet',
     st_setsrid(st_makepoint(-75.05, 39.91), 4326)::geography, now() - interval '1 hour', now() + interval '1 hour', 'public');
  insert into meet_rsvps (meet_id, user_id, status, car_id)
    values ('cccccccc-0000-4000-8003-000000000004', a::uuid, 'going', car_a::uuid);
  insert into meet_checkins (meet_id, user_id) values ('cccccccc-0000-4000-8003-000000000004', b::uuid);
  perform pg_temp.allow('meet_votes: checked-in person picks a car by upsert', b,
    format($s$insert into meet_votes (meet_id, voter_id, car_id) values ('cccccccc-0000-4000-8003-000000000004', %L, %L)
      on conflict (meet_id, voter_id) do update
      set meet_id = excluded.meet_id, voter_id = excluded.voter_id, car_id = excluded.car_id$s$, b, car_a));
  perform pg_temp.deny('meet_votes: cannot pick as someone else', b,
    format($s$insert into meet_votes (meet_id, voter_id, car_id) values ('cccccccc-0000-4000-8003-000000000004', %L, %L)$s$, a, car_a));

  insert into listing_photos (listing_id, path) values (lst_a::uuid, a || '/top.jpg');
  perform pg_temp.allow('listing_photos: readable with the listing', b,
    format($s$select 1 from listing_photos where listing_id = %L$s$, lst_a));
  update listings set hidden_at = now() where id = lst_a::uuid;
  perform pg_temp.deny('listing_photos: hidden with the listing', b,
    format($s$select 1 from listing_photos where listing_id = %L$s$, lst_a));
  update listings set hidden_at = null where id = lst_a::uuid;

  insert into post_comments (post_id, author_id, body) values (post_a::uuid, b::uuid, 'Check: comment');
  perform pg_temp.allow('post_comments: readable with the post', b,
    format($s$select 1 from post_comments where post_id = %L$s$, post_a));
  perform pg_temp.deny('post_comments: hidden with the post across a block', c,
    format($s$select 1 from post_comments where post_id = %L$s$, post_a));

  perform moderation_suspend(a);
  perform pg_temp.deny('race_results: runs by a suspended account drop out', b,
    format($s$select 1 from race_results where user_id = %L$s$, a));
  perform moderation_unsuspend(a);

  insert into team_roles (id, team_id, name, permissions)
    values ('cccccccc-0000-4000-800a-000000000001', team_p::uuid, 'Role manager', 4);
  update team_members set role_id = 'cccccccc-0000-4000-800a-000000000001'
    where team_id = team_p::uuid and user_id = b::uuid;
  perform pg_temp.allow('team_roles: manage_roles adds a role within its own permissions', b,
    format($s$insert into team_roles (team_id, name, permissions) values (%L, 'Helper', 4)$s$, team_p));
  perform pg_temp.deny('team_roles: manage_roles cannot grant permissions it lacks', b,
    format($s$insert into team_roles (team_id, name, permissions) values (%L, 'Boss', 63)$s$, team_p));
  perform pg_temp.deny('team_members: manage_roles cannot hand out the Owner role', b,
    format($s$update team_members set role_id = (select id from team_roles where team_id = %L and name = 'Owner')
      where team_id = %L and user_id = %L$s$, team_p, team_p, b));

  perform pg_temp.allow('storage: owner uploads a message attachment', a,
    format($s$insert into storage.objects (bucket_id, name) values ('messages', %L)$s$, a || '/dm.jpg'), true);
  perform pg_temp.allow('storage: owner lists own message attachments', a,
    format($s$select 1 from storage.objects where bucket_id = 'messages' and name = %L$s$, a || '/dm.jpg'));
  perform pg_temp.deny('storage: others cannot list message attachments', b,
    $s$select 1 from storage.objects where bucket_id = 'messages'$s$);
  perform pg_temp.deny('storage: anon cannot list message attachments', 'anon',
    $s$select 1 from storage.objects where bucket_id = 'messages'$s$);

  ---------------------------------------------------------------- export_my_data (ACC-12)
  insert into messages (thread_id, author_id, body) values (thr_ab::uuid, a::uuid, 'Export check from Avery');
  insert into device_tokens (user_id, apns_token) values (a::uuid, 'exportchecktoken');
  perform pg_temp.allow('export_my_data: caller gets own profile and cars', a,
    format($s$select 1 from (select public.export_my_data() d) x
      where d -> 'profile' ->> 'user_id' = %L and d -> 'cars' @> jsonb_build_array(jsonb_build_object('id', %L))$s$, a, car_a));
  perform pg_temp.allow('export_my_data: includes messages the caller sent', a,
    $s$select 1 from jsonb_array_elements(public.export_my_data() -> 'messages') m
      where m ->> 'body' = 'Export check from Avery'$s$);
  perform pg_temp.deny('export_my_data: no messages the caller received', a,
    format($s$select 1 from jsonb_array_elements(public.export_my_data() -> 'messages') m
      where m ->> 'author_id' <> %L$s$, a));
  perform pg_temp.deny('export_my_data: no device tokens', a,
    $s$select 1 where public.export_my_data()::text like '%exportchecktoken%'$s$);
  perform pg_temp.deny('export_my_data: another user''s cars, posts and messages are absent', b,
    format($s$select 1 from (select public.export_my_data() d) x
      where d -> 'profile' ->> 'user_id' <> %1$L
         or exists (select 1 from jsonb_array_elements(d -> 'cars') c where c ->> 'owner_id' <> %1$L)
         or exists (select 1 from jsonb_array_elements(d -> 'posts') p where p ->> 'author_id' <> %1$L)
         or exists (select 1 from jsonb_array_elements(d -> 'messages') m where m ->> 'author_id' <> %1$L)
         or d::text like '%%Export check from Avery%%'$s$, b));
  perform pg_temp.deny('export_my_data: not callable by anon', 'anon',
    $s$select public.export_my_data()$s$);
  delete from device_tokens where apns_token = 'exportchecktoken';

  ---------------------------------------------------------------- build cost (W10-4, GAR-18)
  perform pg_temp.allow('build_entries: owner logs an entry with a cost', a,
    format($s$insert into build_entries (car_id, title, cost_cents) values (%L, 'Cost check exhaust', 84900)$s$, car_a), true);
  perform pg_temp.allow('build_entries: another user still reads the entry', b,
    format($s$select id, title from build_entries where car_id = %L and title = 'Cost check exhaust'$s$, car_a));
  perform pg_temp.deny('build_entries: another user cannot select the cost', b,
    format($s$select cost_cents from build_entries where car_id = %L$s$, car_a), '42501');
  perform pg_temp.deny('build_entries: another user cannot select * (it would carry the cost)', b,
    format($s$select * from build_entries where car_id = %L$s$, car_a), '42501');
  perform pg_temp.deny('build_entries: another user cannot filter on the cost', b,
    format($s$select id from build_entries where car_id = %L and cost_cents > 0$s$, car_a), '42501');
  perform pg_temp.deny('build_entries: another user cannot set a cost', b,
    format($s$update build_entries set cost_cents = 1 where car_id = %L$s$, car_a));
  perform pg_temp.allow('build_costs: owner reads own costs', a,
    format($s$select 1 from build_costs(%L) where cost_cents = 84900$s$, car_a));
  perform pg_temp.deny('build_costs: another user gets nothing', b,
    format($s$select 1 from build_costs(%L)$s$, car_a));
  perform pg_temp.deny('build_costs: not callable by anon', 'anon',
    format($s$select 1 from build_costs(%L)$s$, car_a));
  perform pg_temp.allow('build_entries: owner changes a cost', a,
    format($s$update build_entries set cost_cents = 90000 where car_id = %L and title = 'Cost check exhaust'$s$, car_a));
  perform pg_temp.deny('build_entries: cost cannot be negative', a,
    format($s$update build_entries set cost_cents = -1 where car_id = %L and title = 'Cost check exhaust'$s$, car_a), '23514');

  ---------------------------------------------------------------- team_standings (W10-7)
  -- B's car won a vote this week (cast_showdown_vote above); B is in private team P.
  perform pg_temp.allow('team_standings: setup, B joins the public team', b,
    format($s$insert into team_members (team_id, user_id) values (%L, %L)$s$, team_o, b), true);
  perform pg_temp.allow('team_standings: a public team is listed with its score and rank', c,
    format($s$select 1 from team_standings() s where team_id = %L and score >= 1
      and rank = (select count(*) + 1 from team_standings() t2 where t2.score > s.score)$s$, team_o));
  perform pg_temp.allow('team_standings: a member sees their private team', b,
    format($s$select 1 from team_standings() where team_id = %L and score >= 1$s$, team_p));
  perform pg_temp.deny('team_standings: a private team is hidden from non-members', c,
    format($s$select 1 from team_standings(%L) where team_id = %L$s$, team_p, team_p));
  perform pg_temp.deny('team_standings: not callable by anon', 'anon',
    $s$select 1 from team_standings()$s$);
  perform pg_temp.truth('team_standings: returns only team id, name, tag, icon, score and rank',
    (select pg_get_function_result('public.team_standings(uuid)'::regprocedure)
       = 'TABLE(team_id uuid, name text, tag text, icon_path text, score integer, rank integer)'));

  ---------------------------------------------------------------- W10-9 road loops (ROAD-6)
  perform pg_temp.allow('road_loops: owner creates a loop', a,
    format($s$insert into road_loops (id, owner_id, name, road_ids) values ('cccccccc-0000-4000-8109-00000000000a', %L,
      'Check loop', array['cccccccc-0000-4000-8007-00000000000a']::uuid[])$s$, a), true);
  perform pg_temp.deny('road_loops: cannot create as someone else', b,
    format($s$insert into road_loops (owner_id, name, road_ids) values (%L, 'x',
      array['cccccccc-0000-4000-8007-00000000000a']::uuid[])$s$, a));
  perform pg_temp.deny('road_loops: a loop needs at least one road', a,
    format($s$insert into road_loops (owner_id, name, road_ids) values (%L, 'x', '{}')$s$, a), '23514');
  perform pg_temp.allow('road_loops: owner renames and reorders', a,
    $s$update road_loops set name = 'Check loop 2', road_ids = road_ids || road_ids
       where id = 'cccccccc-0000-4000-8109-00000000000a'$s$);
  perform pg_temp.deny('road_loops: others cannot list loops', b,
    $s$select 1 from road_loops$s$);
  perform pg_temp.deny('road_loops: others cannot rename', b,
    $s$update road_loops set name = 'x' where id = 'cccccccc-0000-4000-8109-00000000000a'$s$);
  perform pg_temp.deny('road_loops: others cannot delete', b,
    $s$delete from road_loops where id = 'cccccccc-0000-4000-8109-00000000000a'$s$);
  perform pg_temp.deny('road_loops: not readable by anon', 'anon',
    $s$select 1 from road_loops$s$);
  perform pg_temp.allow('road_loop: a signed-in user with the id reads it', b,
    $s$select 1 from road_loop('cccccccc-0000-4000-8109-00000000000a')$s$);
  perform pg_temp.deny('road_loop: an unknown id returns nothing', b,
    $s$select 1 from road_loop('cccccccc-0000-4000-8109-0000000000ff')$s$);
  insert into blocks (blocker_id, blocked_id) values (a::uuid, c::uuid) on conflict do nothing;
  perform pg_temp.deny('road_loop: hidden across a block', c,
    $s$select 1 from road_loop('cccccccc-0000-4000-8109-00000000000a')$s$);
  perform pg_temp.deny('road_loop: not callable by anon', 'anon',
    $s$select 1 from road_loop('cccccccc-0000-4000-8109-00000000000a')$s$);
  perform pg_temp.allow('road_loops: owner deletes own loop', a,
    $s$delete from road_loops where id = 'cccccccc-0000-4000-8109-00000000000a'$s$);

  ---------------------------------------------------------------- saved builds (MOD-15)
  perform pg_temp.allow('saved_builds: owner saves builds on own car', a,
    format($s$update cars set saved_builds = '[{"id":"cccccccc-0000-4000-800a-000000000001","name":"Street","mods":["catback"]}]' where id = %L$s$, car_a), true);
  perform pg_temp.deny('saved_builds: non-owner cannot write', b,
    format($s$update cars set saved_builds = '[]' where id = %L$s$, car_a));
  perform pg_temp.allow('saved_builds: readable where the car is', b,
    format($s$select 1 from cars where id = %L and saved_builds -> 0 ->> 'name' = 'Street'$s$, car_a));
  perform pg_temp.deny('saved_builds: hidden from users the owner blocked', c,
    format($s$select 1 from cars where id = %L and jsonb_array_length(saved_builds) > 0$s$, car_a));
  perform pg_temp.deny('saved_builds: anon cannot read', 'anon',
    $s$select 1 from cars where jsonb_array_length(saved_builds) > 0$s$);
  perform pg_temp.deny('saved_builds: at most three per car', a,
    format($s$update cars set saved_builds = '[{"name":"1"},{"name":"2"},{"name":"3"},{"name":"4"}]' where id = %L$s$, car_a), '23514');

  ---------------------------------------------------------------- meet capacity (MEET-15)
  insert into meets (id, host_id, title, kind, geom, starts_at, ends_at, visibility, capacity) values
    ('cccccccc-0000-4000-8003-000000000015', b::uuid, 'Check: capped meet', 'meet',
     st_setsrid(st_makepoint(-75.05, 39.91), 4326)::geography, now() + interval '1 day', now() + interval '1 day 2 hours', 'public', 1);
  perform pg_temp.allow('meet_rsvps: Going under the cap', a,
    format($s$insert into meet_rsvps (meet_id, user_id) values ('cccccccc-0000-4000-8003-000000000015', %L)$s$, a), true);
  insert into meet_rsvps (meet_id, user_id) values ('cccccccc-0000-4000-8003-000000000015', c::uuid);
  perform pg_temp.truth('meet_rsvps: Going past the cap joins the waitlist',
    exists (select 1 from meet_rsvps where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = a::uuid and status = 'going')
    and exists (select 1 from meet_rsvps where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = c::uuid
                and status::text = 'waitlist' and waitlisted_at is not null));
  update meet_rsvps set status = 'going', waitlisted_at = null
    where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = c::uuid;
  perform pg_temp.truth('meet_rsvps: a waiting RSVP cannot seat itself',
    exists (select 1 from meet_rsvps where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = c::uuid
            and status::text = 'waitlist' and waitlisted_at is not null));
  perform pg_temp.deny('meets: capacity changes only through the gateway', b,
    $s$update meets set capacity = 50 where id = 'cccccccc-0000-4000-8003-000000000015'$s$);
  perform pg_temp.allow('meet_rsvps: someone Going drops', a,
    format($s$delete from meet_rsvps where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = %L$s$, a), true);
  perform pg_temp.truth('meet_rsvps: the first waiting person becomes Going and is told once',
    exists (select 1 from meet_rsvps where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = c::uuid
            and status = 'going' and waitlisted_at is null)
    and (select count(*) from notifications where user_id = c::uuid
          and dedupe_key = 'meet_spot:cccccccc-0000-4000-8003-000000000015') = 1
    and (select count(*) from meet_promotions where meet_id = 'cccccccc-0000-4000-8003-000000000015' and user_id = c::uuid) = 1);
  perform pg_temp.deny('meet_promotions: not readable by signed-in users', c,
    $s$select 1 from meet_promotions$s$);
  perform pg_temp.deny('meet_promotions: not readable by anon', 'anon',
    $s$select 1 from meet_promotions$s$);

  ---------------------------------------------------------------- car of the week (STR-11)
  perform pg_temp.truth('car_of_week: a pick exists for this week',
    exists (select 1 from public.car_of_week_current()));
  perform pg_temp.truth('car_of_week: the pick comes from the pool',
    exists (select 1 from public.car_of_week_current() c
            join public.car_of_week_pool p on p.variant_id = c.variant_id));
  perform pg_temp.deny('car_of_week_picks: not readable by users', a,
    $s$select 1 from car_of_week_picks$s$);
  perform pg_temp.deny('car_of_week_pool: not readable by users', a,
    $s$select 1 from car_of_week_pool$s$);
  perform pg_temp.deny('car_of_week_runs: not readable directly', a,
    $s$select 1 from car_of_week_runs$s$);
  perform pg_temp.deny('car_of_week_runs: not writable directly', a,
    format($s$insert into car_of_week_runs (user_id, week_start, variant_id, et_ms)
      values (%L, (select week_start from public.car_of_week_current()), 1, 12000)$s$, a));
  perform pg_temp.allow('car_of_week_save: user saves a run', a,
    $s$select public.car_of_week_save(12400, 1180, 420, 2)$s$, true);
  perform pg_temp.deny('car_of_week_save: implausible time refused', a,
    $s$select public.car_of_week_save(500, null, null, 2)$s$, '22023,23514');
  perform pg_temp.allow('car_of_week_save: friend saves a run', b,
    $s$select public.car_of_week_save(12050, 1150, 380, 2)$s$, true);
  perform pg_temp.allow('car_of_week_save: teammate saves a run', c,
    $s$select public.car_of_week_save(12500, 1210, 500, 2)$s$, true);
  perform pg_temp.truth('car_of_week_save: the week and pick are stamped server-side',
    exists (select 1 from public.car_of_week_runs r
            join public.car_of_week_current() c on c.week_start = r.week_start
            where r.user_id = a::uuid and r.variant_id = c.variant_id));
  -- C shares no team or friendship with A or B yet: only their own run lists.
  perform pg_temp.allow('car_of_week_board: own run listed', c,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000c'$s$);
  perform pg_temp.deny('car_of_week_board: unrelated users hidden', c,
    $s$select 1 from public.car_of_week_board() where user_id in
      ('cccccccc-0000-4000-8000-00000000000a', 'cccccccc-0000-4000-8000-00000000000b')$s$);
  -- C joins the public team A owns: now a teammate of A, still hidden from A (A blocked C)
  -- but visible to B, who shares the team and blocked nobody.
  perform pg_temp.allow('car_of_week setup: C joins the public team', c,
    format($s$insert into team_members (team_id, user_id) values (%L, %L)$s$, team_o, c), true);
  perform pg_temp.allow('car_of_week_board: own run listed', a,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000a'$s$);
  perform pg_temp.allow('car_of_week_board: friend and teammate run listed', a,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000b'$s$);
  perform pg_temp.deny('car_of_week_board: blocked teammate hidden', a,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000c'$s$);
  perform pg_temp.allow('car_of_week_board: blocked user sees teammates', c,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000b'$s$);
  perform pg_temp.deny('car_of_week_board: block hides the blocker too', c,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000a'$s$);
  perform pg_temp.allow('car_of_week_board: friend sees the teammate', b,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000c'$s$);
  perform pg_temp.deny('car_of_week_board: not callable by anon', 'anon',
    $s$select * from public.car_of_week_board()$s$);
  perform moderation_suspend(b);
  perform pg_temp.deny('car_of_week_board: suspended runs drop out', a,
    $s$select 1 from public.car_of_week_board() where user_id = 'cccccccc-0000-4000-8000-00000000000b'$s$);
  perform moderation_unsuspend(b);

  ---------------------------------------------------------------- w11-h hardening
  -- verb coverage and column grants
  insert into spots (id, spotter_id, make, model) values
    ('cccccccc-0000-4000-8010-0000000000a1', a::uuid, 'Honda', 'Fit'),
    ('cccccccc-0000-4000-8010-0000000000a2', b::uuid, 'Honda', 'Fit');
  perform pg_temp.allow('w11h spots: owner deletes own spot', a,
    $s$delete from spots where id = 'cccccccc-0000-4000-8010-0000000000a1'$s$);
  perform pg_temp.deny('w11h spots: non-owner cannot delete', a,
    $s$delete from spots where id = 'cccccccc-0000-4000-8010-0000000000a2'$s$);
  perform pg_temp.deny('w11h post_photos: update revoked', a,
    $s$update post_photos set sort = 9$s$);
  perform pg_temp.deny('w11h post_photos: delete revoked', a,
    $s$delete from post_photos$s$);
  perform pg_temp.deny('w11h follows: update revoked', a,
    $s$update follows set created_at = now()$s$);
  perform pg_temp.deny('w11h listing_saves: update revoked', b,
    $s$update listing_saves set created_at = now()$s$);
  perform pg_temp.deny('w11h meet_rsvps: on_the_way_until not insertable', c,
    format($s$insert into meet_rsvps (meet_id, user_id, status, car_id, on_the_way_until)
      values (%L, %L, 'going', null, now())$s$, meet_pub, c), '42501');
  perform pg_temp.deny('w11h meet_rsvps: on_the_way_until not updatable', b,
    format($s$update meet_rsvps set on_the_way_until = now() where meet_id = %L$s$, meet_pub), '42501');
  perform pg_temp.deny('w11h posts: created_at not insertable', a,
    format($s$insert into posts (author_id, video_path, created_at) values (%L, 'x.mp4', now())$s$, a), '42501');
  perform pg_temp.deny('w11h content_reports: resolved_at not insertable', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason, resolved_at)
      values (%L, 'post', 'x', 'spam', now())$s$, b), '42501');
  perform pg_temp.deny('w11h messages: created_at not insertable', a,
    format($s$insert into messages (thread_id, author_id, body, created_at)
      values (%L, %L, 'hi', now())$s$, thr_ab, a), '42501');
  perform pg_temp.deny('w11h threads: created_at not insertable', a,
    format($s$insert into threads (kind, a_id, b_id, created_at) values ('dm', %L, %L, now())$s$, a, c), '42501');

  -- storage: SQL-side size and MIME limits on every bucket
  perform pg_temp.truth('w11h storage: size and MIME limits on every bucket',
    (select count(*) = 7 from storage.buckets
      where id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages')
        and file_size_limit = 15728640 and cardinality(allowed_mime_types) > 0)
    and (select file_size_limit = 52428800 and cardinality(allowed_mime_types) > 0
         from storage.buckets where id = 'catalog'));

  -- indexes for foreign keys and the client/gateway query patterns
  perform pg_temp.truth('w11h indexes: FK and query indexes exist',
    (select count(*) = 32 from pg_indexes where schemaname = 'public' and indexname in (
      'profiles_primary_car_idx', 'reports_author_idx', 'meets_host_idx', 'meets_team_idx',
      'meets_road_idx', 'meets_winner_idx', 'meet_rsvps_car_idx', 'meet_rsvps_waitlist_idx',
      'meet_checkins_user_idx', 'meet_votes_voter_idx', 'meet_votes_car_fk_idx',
      'meet_promotions_user_idx', 'venue_notes_author_idx', 'roads_author_idx',
      'road_ratings_user_idx', 'listings_car_idx', 'threads_listing_idx', 'posts_car_idx',
      'read_markers_channel_idx', 'read_markers_thread_idx', 'race_results_car_idx',
      'help_responses_user_idx', 'showdown_votes_winner_idx', 'showdown_votes_loser_idx',
      'notifications_actor_idx', 'content_reports_reporter_idx', 'post_comments_author_idx',
      'teams_owner_idx', 'messages_author_idx', 'report_votes_user_idx',
      'help_requests_requester_idx', 'device_tokens_apns_idx')));
  perform pg_temp.truth('w11h indexes: late-table FK indexes exist',
    (select count(*) = 2 from pg_indexes where schemaname = 'public' and indexname in (
      'car_of_week_runs_user_idx', 'message_reactions_user_idx')));

  -- bounded set-returning RPCs: authenticated only, anon refused
  perform pg_temp.deny('w11h following_feed: not callable by anon', 'anon',
    $s$select * from following_feed()$s$);
  perform pg_temp.deny('w11h saved_listings: not callable by anon', 'anon',
    $s$select * from saved_listings()$s$);
  perform pg_temp.deny('w11h channel_unread: not callable by anon', 'anon',
    $s$select * from channel_unread()$s$);
  perform pg_temp.truth('w11h rpcs: execute granted to authenticated, not anon',
    has_function_privilege('authenticated', 'public.following_feed(timestamp with time zone, integer)', 'execute')
    and has_function_privilege('authenticated', 'public.saved_listings(integer)', 'execute')
    and has_function_privilege('authenticated', 'public.channel_unread()', 'execute')
    and has_function_privilege('authenticated', 'public.build_costs(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.following_feed(timestamp with time zone, integer)', 'execute')
    and not has_function_privilege('anon', 'public.saved_listings(integer)', 'execute')
    and not has_function_privilege('anon', 'public.channel_unread()', 'execute')
    and not has_function_privilege('anon', 'public.build_costs(uuid)', 'execute'));
  perform pg_temp.allow('w11h saved_listings: caller sees own saves', b,
    $s$select * from saved_listings()$s$);

  -- input checks: every new constraint exists, plus behavioural spot checks
  perform pg_temp.truth('w11h constraints: all length/range/size checks exist',
    (select count(*) = 28 from pg_constraint where conname in (
      'profiles_avatar_path_len', 'car_photos_path_len', 'build_entries_photo_path_len',
      'build_entries_mod_id_len', 'build_entries_cost_max', 'build_entries_happened_on_range',
      'posts_video_path_len', 'posts_poster_path_len', 'listing_photos_path_len',
      'spots_photo_path_len', 'spots_catalog_model_id_pos', 'messages_attachment_path_len',
      'teams_icon_path_len', 'cars_spec_overrides_size', 'cars_mods_size',
      'race_results_mods_size', 'race_results_reaction_ms_range', 'race_results_trap_max',
      'race_results_sixty_max', 'race_results_model_version_max',
      'showdown_entries_rating_range', 'listings_price_max', 'convoys_id_len',
      'convoys_join_code_fmt', 'convoys_state_size', 'car_of_week_runs_trap_max',
      'car_of_week_runs_reaction_max', 'car_of_week_runs_model_max')));
  perform pg_temp.deny('w11h constraints: oversized JSONB refused', a,
    format($s$update cars set spec_overrides = jsonb_build_object('pad', repeat('x', 5000))
      where id = %L$s$, car_a), '23514');
  perform pg_temp.deny('w11h constraints: listing price cap', a,
    format($s$update listings set price_cents = 100000001 where id = %L$s$, lst_a), '23514');
  perform pg_temp.deny('w11h constraints: race reaction cap', a,
    format($s$insert into race_results (user_id, car_id, et_ms, reaction_ms)
      values (%L, %L, 15000, 60001)$s$, a, car_a), '23514');
  perform pg_temp.deny('w11h constraints: message attachment path cap', a,
    format($s$insert into messages (thread_id, author_id, attachment_path)
      values (%L, %L, repeat('x', 301))$s$, thr_ab, a), '23514');
  perform pg_temp.deny('w11h constraints: convoy join code format', 'service',
    $s$insert into convoys (id, join_code, state) values ('chk-convoy-bad', 'bad code!', '{}')$s$, '23514');

  -- default privileges: a table created now grants anon nothing
  execute 'create table public.w11h_probe (id int)';
  perform pg_temp.truth('w11h defaults: anon has no privileges on new public tables',
    not has_table_privilege('anon', 'public.w11h_probe', 'select')
    and not has_table_privilege('anon', 'public.w11h_probe', 'insert'));
  execute 'drop table public.w11h_probe';

  ---------------------------------------------------------------- reactions and mute (MSG-11, SAFE-12)
  perform pg_temp.allow('messages setup: A posts in the team channel', a,
    format($s$insert into messages (channel_id, author_id, body) values (%L, %L, 'react to me')$s$, general_p, a), true);
  select id into msg_b from messages where body = 'react to me';
  perform pg_temp.allow('message_reactions: member reacts', b,
    format($s$insert into message_reactions (message_id, user_id, reaction) values (%s, %L, 'fire')$s$, msg_b, b), true);
  perform pg_temp.deny('message_reactions: only the six fixed reactions', b,
    format($s$insert into message_reactions (message_id, user_id, reaction) values (%s, %L, 'party')$s$, msg_b, b), '23514');
  perform pg_temp.deny('message_reactions: cannot react as someone else', b,
    format($s$insert into message_reactions (message_id, user_id, reaction) values (%s, %L, 'heart')$s$, msg_b, a));
  perform pg_temp.allow('message_reactions: reader sees counts', a,
    format($s$select 1 from message_reactions where message_id = %s$s$, msg_b));
  perform pg_temp.deny('message_reactions: outsiders cannot read', c,
    format($s$select 1 from message_reactions where message_id = %s$s$, msg_b));
  perform pg_temp.deny('message_reactions: anon cannot read', 'anon',
    $s$select 1 from message_reactions$s$);
  perform pg_temp.allow('message_reaction_counts: page query returns rows', a,
    format($s$select * from message_reaction_counts(array[%s]::bigint[])$s$, msg_b));
  perform pg_temp.deny('message_reaction_counts: not callable by anon', 'anon',
    format($s$select * from message_reaction_counts(array[%s]::bigint[])$s$, msg_b));
  perform pg_temp.allow('message_reactions: author removes own', b,
    format($s$delete from message_reactions where message_id = %s and user_id = %L$s$, msg_b, b));
  perform pg_temp.deny('message_reactions: cannot remove someone else''s', b,
    format($s$delete from message_reactions where message_id = %s and user_id = %L$s$, msg_b, a));
  perform moderation_suspend(b);
  perform pg_temp.deny('message_reactions: suspended cannot react', b,
    format($s$insert into message_reactions (message_id, user_id, reaction) values (%s, %L, 'wrench')$s$, msg_b, b), '42501,PT423');
  perform moderation_unsuspend(b);

  perform pg_temp.allow('mutes: owner mutes a person', a,
    format($s$insert into mutes (owner_id, target_kind, target_id) values (%L, 'user', %L)$s$, a, b), true);
  perform pg_temp.allow('mutes: owner reads own mutes', a, $s$select 1 from mutes$s$);
  perform pg_temp.deny('mutes: others cannot read', b, $s$select 1 from mutes$s$);
  perform pg_temp.deny('mutes: anon cannot read', 'anon', $s$select 1 from mutes$s$);
  perform pg_temp.deny('mutes: cannot mute for someone else', b,
    format($s$insert into mutes (owner_id, target_kind, target_id) values (%L, 'user', %L)$s$, a, c));
  perform pg_temp.deny('mutes: unknown target kind refused', a,
    format($s$insert into mutes (owner_id, target_kind, target_id) values (%L, 'car', %L)$s$, a, c), '23514');
  perform pg_temp.truth('mutes: muted actor writes no activity row',
    not public.record_notification(a::uuid, 'like', b::uuid, 'waypoints://post/x', 't', 'b', null));
  perform pg_temp.truth('mutes: is_muted matches a muted person',
    public.is_muted(a::uuid, b::uuid, null));
  perform pg_temp.allow('mutes: owner also mutes the channel', a,
    format($s$insert into mutes (owner_id, target_kind, target_id) values (%L, 'channel', %L)$s$, a, general_p), true);
  perform pg_temp.truth('mutes: is_muted matches a muted channel',
    public.is_muted(a::uuid, c::uuid, 'waypoints://channel/' || general_p));
  perform pg_temp.truth('mutes: unrelated urls are not muted',
    not public.is_muted(a::uuid, c::uuid, 'waypoints://channel/cccccccc-0000-4000-8000-0000000000ff'));
  perform pg_temp.allow('mutes: owner also mutes the team', a,
    format($s$insert into mutes (owner_id, target_kind, target_id) values (%L, 'team', %L)$s$, a, team_p), true);
  perform pg_temp.allow('mutes: lift the channel mute', a,
    format($s$delete from mutes where owner_id = %L and target_kind = 'channel'$s$, a), true);
  perform pg_temp.truth('mutes: is_muted matches a muted team channel and meet',
    public.is_muted(a::uuid, c::uuid, 'waypoints://channel/' || general_p)
    and public.is_muted(a::uuid, c::uuid, 'waypoints://meet/cccccccc-0000-4000-8003-000000000003'));
  perform pg_temp.allow('mutes: an expired mute does not apply', b,
    format($s$insert into mutes (owner_id, target_kind, target_id, until) values (%L, 'user', %L, now() - interval '1 hour')$s$, b, a), true);
  perform pg_temp.truth('mutes: expired mute is ignored',
    not public.is_muted(b::uuid, a::uuid, null));
  perform pg_temp.truth('mutes: unmuted actor still writes activity rows',
    public.record_notification(b::uuid, 'like', a::uuid, 'waypoints://post/y', 't', 'b', null));
  perform pg_temp.deny('is_muted: not callable by users', a,
    $s$select public.is_muted('cccccccc-0000-4000-8000-00000000000a'::uuid,
      'cccccccc-0000-4000-8000-00000000000b'::uuid, 'x')$s$);
  perform pg_temp.allow('mutes: owner unmutes', a,
    format($s$delete from mutes where owner_id = %L and target_kind = 'user' and target_id = %L$s$, a, b));

  ---------------------------------------------------------------- block gaps (W11-H-6)
  -- a blocked c back in the "blocks" section above. These prove spots_read,
  -- teams_read, and venue_notes_read now hide content across a block while
  -- content_reports still files (SAFE-1, SAFE-2).
  perform pg_temp.allow('w11h6 setup: owner adds a venue note', a,
    format($s$insert into venue_notes (geom, author_id, note) values
      (st_setsrid(st_makepoint(-75.025, 39.945), 4326)::geography, %L, 'Check: blocked note')$s$, a), true);
  perform pg_temp.truth('w11h6 setup: fixtures exist (a''s spot, a''s public team, a''s note)',
    exists (select 1 from spots where spotter_id = a::uuid and model = 'Supra')
    and exists (select 1 from teams where id = team_o::uuid and owner_id = a::uuid)
    and exists (select 1 from venue_notes where note = 'Check: blocked note'));
  perform pg_temp.truth('w11h6 policies: is_blocked_pair on all three reads',
    (select count(*) = 3 from pg_policies
      where schemaname = 'public'
        and ((tablename = 'spots' and policyname = 'spots_read')
          or (tablename = 'teams' and policyname = 'teams_read')
          or (tablename = 'venue_notes' and policyname = 'venue_notes_read'))
        and qual like '%is_blocked_pair%'));

  perform pg_temp.allow('w11h6 setup: blocked user logs a spot of their own', c,
    format($s$insert into spots (spotter_id, make, model) values (%L, 'Nissan', 'Silvia')$s$, c), true);
  perform pg_temp.deny('w11h6 spots: hidden from a user the spotter blocked', c,
    format($s$select 1 from spots where spotter_id = %L$s$, a));
  perform pg_temp.deny('w11h6 spots: hidden from the spotter too (both directions)', a,
    format($s$select 1 from spots where spotter_id = %L and model = 'Silvia'$s$, c));
  perform pg_temp.allow('w11h6 spots: spotter still sees own spot', c,
    format($s$select 1 from spots where spotter_id = %L and model = 'Silvia'$s$, c));
  perform pg_temp.allow('w11h6 spots: still readable by an unblocked user', b,
    format($s$select 1 from spots where spotter_id = %L$s$, a));
  perform pg_temp.deny('w11h6 spots: anon cannot read', 'anon', $s$select 1 from spots$s$);

  perform pg_temp.deny('w11h6 teams: public team hidden across a block', c,
    format($s$select 1 from teams where id = %L$s$, team_o));
  perform pg_temp.allow('w11h6 teams: owner still sees own team', a,
    format($s$select 1 from teams where id = %L$s$, team_o));
  perform pg_temp.allow('w11h6 teams: still readable by an unblocked user', b,
    format($s$select 1 from teams where id = %L$s$, team_o));
  perform pg_temp.deny('w11h6 teams: anon cannot read', 'anon', $s$select 1 from teams$s$);

  perform pg_temp.deny('w11h6 venue_notes: hidden across a block', c,
    $s$select 1 from venue_notes where note = 'Check: blocked note'$s$);
  perform pg_temp.allow('w11h6 venue_notes: still readable by an unblocked user', b,
    $s$select 1 from venue_notes where note = 'Check: blocked note'$s$);
  perform pg_temp.deny('w11h6 venue_notes: anon cannot read', 'anon', $s$select 1 from venue_notes$s$);

  perform pg_temp.allow('w11h6 content_reports: blocked user can still report a team', c,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason)
      values (%L, 'team', %L, 'spam')$s$, c, team_o));
  perform pg_temp.allow('w11h6 content_reports: report on a spot still files', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason)
      select %L, 'spot', id::text, 'spam' from spots where spotter_id = %L$s$, b, a));
  perform pg_temp.deny('w11h6 content_reports: anon cannot file', 'anon',
    $s$insert into content_reports (reporter_id, target_kind, target_id, reason)
       values ('cccccccc-0000-4000-8000-00000000000b', 'team', 'x', 'spam')$s$);

  ---------------------------------------------------------------- private messages bucket (W11-H-5)
  perform pg_temp.truth('w11h5 storage: messages bucket is private, the rest public',
    (select not public from storage.buckets where id = 'messages')
    and (select count(*) = 7 from storage.buckets
         where public and id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'catalog')));
  -- A DM attachment: the object and the message row pointing at it.
  perform pg_temp.allow('w11h5 setup: uploader stores a DM attachment', a,
    format($s$insert into storage.objects (bucket_id, name) values ('messages', %L)$s$,
      a || '/dm-private.jpg'), true);
  perform pg_temp.allow('w11h5 setup: DM message references the attachment', a,
    format($s$insert into messages (thread_id, author_id, body, attachment_path)
      values (%L, %L, 'pic', %L)$s$, thr_ab, a, a || '/dm-private.jpg'), true);
  perform pg_temp.allow('w11h5 storage: uploader reads own DM attachment', a,
    format($s$select 1 from storage.objects where bucket_id = 'messages' and name = %L$s$,
      a || '/dm-private.jpg'));
  perform pg_temp.allow('w11h5 storage: thread party reads the DM attachment', b,
    format($s$select 1 from storage.objects where bucket_id = 'messages' and name = %L$s$,
      a || '/dm-private.jpg'));
  perform pg_temp.deny('w11h5 storage: outsider cannot read the DM attachment', c,
    format($s$select 1 from storage.objects where bucket_id = 'messages' and name = %L$s$,
      a || '/dm-private.jpg'));
  perform pg_temp.deny('w11h5 storage: anon cannot read the DM attachment', 'anon',
    format($s$select 1 from storage.objects where bucket_id = 'messages' and name = %L$s$,
      a || '/dm-private.jpg'));

  ---------------------------------------------------------------- word filter (L20, SAFE-4)
  -- Same mirror as the client WordList: slurs and threats reject the write
  -- with check_violation; ordinary swearing passes.
  perform pg_temp.truth('text_is_clean: blocked words rejected, ordinary swearing allowed',
    public.text_is_clean('nice run') and public.text_is_clean('shit happens')
    and not public.text_is_clean('you are a fag') and not public.text_is_clean('kys')
    and not public.text_is_clean('killyourself loser') and not public.text_is_clean('a FAG.'));
  perform pg_temp.deny('word_filter profiles: slur in bio rejected', a,
    format($s$update profiles set bio = 'total retard' where user_id = %L$s$, a), '23514');
  perform pg_temp.deny('word_filter profiles: slur in handle rejected', a,
    format($s$update profiles set handle = 'faggot' where user_id = %L$s$, a), '23514');
  perform pg_temp.deny('word_filter cars: slur in nickname rejected', a,
    format($s$update cars set nickname = 'kys' where id = %L$s$, car_a), '23514');
  perform pg_temp.deny('word_filter teams: slur in name rejected', a,
    format($s$insert into teams (owner_id, name, tag) values (%L, 'fag crew', 'FGT')$s$, a), '23514');
  perform pg_temp.deny('word_filter teams: slur in about on edit rejected', a,
    format($s$update teams set about = 'kill yourself' where id = %L$s$, team_p), '23514');
  perform pg_temp.deny('word_filter team_roles: slur in role name rejected', a,
    format($s$insert into team_roles (team_id, name) values (%L, 'nigga')$s$, team_p), '23514');
  perform pg_temp.deny('word_filter channels: slur in channel name rejected', a,
    format($s$insert into channels (team_id, name) values (%L, 'fag-room')$s$, team_p), '23514');
  perform pg_temp.deny('word_filter meets: slur in title rejected (gateway path)', 'service',
    format($s$insert into meets (host_id, title, kind, geom, starts_at, ends_at) values (%L, 'spic meet', 'meet',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography, now(), now() + interval '1 hour')$s$, a), '23514');
  perform pg_temp.deny('word_filter meets: slur in details rejected (gateway path)', 'service',
    format($s$update meets set details = 'wetback run' where id = %L$s$, meet_pub), '23514');
  perform pg_temp.deny('word_filter roads: slur in name rejected', a,
    format($s$insert into roads (author_id, name, path) values (%L, 'chink pass',
      st_geogfromtext('SRID=4326;LINESTRING(-74.80 39.99, -74.82 39.98)'))$s$, a), '23514');
  perform pg_temp.deny('word_filter road_loops: slur in loop name rejected', a,
    $s$insert into road_loops (owner_id, name, road_ids) values (auth.uid(), 'kys loop',
      array['cccccccc-0000-4000-8007-00000000000a']::uuid[])$s$, '23514');
  perform pg_temp.deny('word_filter spots: slur in model rejected', a,
    format($s$insert into spots (spotter_id, make, model) values (%L, 'Nissan', 'tranny')$s$, a), '23514');
  perform pg_temp.deny('word_filter venue_notes: slur in note rejected', a,
    format($s$insert into venue_notes (geom, author_id, note) values
      (st_setsrid(st_makepoint(-75.02, 39.94), 4326)::geography, %L, 'kike lot')$s$, a), '23514');
  perform pg_temp.deny('word_filter reports: slur in note rejected (gateway path)', 'service',
    format($s$insert into reports (author_id, kind, geom, note) values (%L, 'hazard',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography, 'nigger ahead')$s$, a), '23514');
  perform pg_temp.deny('word_filter content_reports: slur in note rejected', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason, note)
      values (%L, 'team', %L, 'spam', 'they said kys')$s$, b, team_o), '23514');
  perform pg_temp.deny('word_filter help_requests: slur in note rejected (gateway path)', 'service',
    format($s$insert into help_requests (requester_id, kind, geom, note) values (%L, 'stuck',
      st_setsrid(st_makepoint(-75, 39.9), 4326)::geography, 'retard stuck')$s$, a), '23514');
  perform pg_temp.deny('word_filter posts: slur in caption rejected', a,
    format($s$insert into posts (author_id, caption) values (%L, 'wetback day')$s$, a), '23514');
  perform pg_temp.deny('word_filter post_comments: slur in body rejected', b,
    format($s$insert into post_comments (post_id, author_id, body) values (%L, %L, 'nigga please')$s$, post_a, b), '23514');
  perform pg_temp.deny('word_filter messages: slur in body rejected', a,
    format($s$insert into messages (thread_id, author_id, body) values (%L, %L, 'you fag')$s$, thr_ab, a), '23514');
  perform pg_temp.deny('word_filter listings: slur in title rejected', a,
    format($s$insert into listings (seller_id, kind, title, price_cents, condition)
      values (%L, 'part', 'fag special', 100, 'used')$s$, a), '23514');

  ---------------------------------------------------------------- feed_hidden (L58, FEED-5)
  perform pg_temp.allow('l58 feed_hidden: owner hides a post', a,
    format($s$insert into feed_hidden (user_id, post_id) values (%L, %L)$s$, a, post_a), true);
  perform pg_temp.allow('l58 feed_hidden: owner reads own hidden rows', a,
    format($s$select 1 from feed_hidden where user_id = %L and post_id = %L$s$, a, post_a));
  perform pg_temp.deny('l58 feed_hidden: other user cannot read a hidden row', b,
    format($s$select 1 from feed_hidden where user_id = %L and post_id = %L$s$, a, post_a));
  perform pg_temp.deny('l58 feed_hidden: cannot hide for another user', b,
    format($s$insert into feed_hidden (user_id, post_id) values (%L, %L)$s$, a, post_a));
  perform pg_temp.deny('l58 feed_hidden: anon denied', 'anon',
    format($s$select 1 from feed_hidden where user_id = %L$s$, a));

  ---------------------------------------------------------------- cascade
  delete from storage.objects where name like a || '/%';
  delete from auth.users where id = a::uuid;
  perform pg_temp.truth('profiles: deleting a user cascades everywhere',
    not exists (select 1 from profiles where user_id = a::uuid)
    and not exists (select 1 from cars where owner_id = a::uuid)
    and not exists (select 1 from teams where owner_id = a::uuid)
    and not exists (select 1 from posts where author_id = a::uuid)
    and not exists (select 1 from friendships where a::uuid in (requester_id, addressee_id))
    and not exists (select 1 from notifications where user_id = a::uuid)
    and not exists (select 1 from help_requests where requester_id = a::uuid));

  perform pg_temp.deny('delete_account: not callable by anon', 'anon',
    $s$select public.delete_account()$s$);
  perform pg_temp.allow('delete_account: user deletes own account', c,
    $s$select public.delete_account()$s$, true);
  perform pg_temp.truth('delete_account: auth user and every row removed',
    not exists (select 1 from auth.users where id = c::uuid)
    and not exists (select 1 from profiles where user_id = c::uuid)
    and not exists (select 1 from cars where owner_id = c::uuid));
end
$do$;

select rpad(name, 72, '.') || ' ' || case when ok then 'PASS' else 'FAIL  (' || coalesce(detail, 'condition false') || ')' end
from _checks order by seq;

select format('%s checks: %s passed, %s failed',
              count(*), count(*) filter (where ok), count(*) filter (where not ok))
from _checks;

rollback;
