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
      execute format('select count(*) from (%s) _q', stmt) into n;
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
    format($s$insert into posts (id, author_id, car_id, video_path, caption, duration_ms, like_count)
      values (%L, %L, %L, %L, 'Golden hour on 206', 18000, 500)$s$, post_a, a, car_a, a || '/clip.mp4'), true);
  perform pg_temp.truth('posts: users cannot seed like_count',
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
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason) values (%L, 'post', %L, 'spam')$s$, b, post_a));
  perform pg_temp.deny('content_reports: cannot file as someone else', b,
    format($s$insert into content_reports (reporter_id, target_kind, target_id, reason) values (%L, 'post', 'x', 'spam')$s$, a));
  perform pg_temp.deny('content_reports: users cannot read reports', b,
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
  perform pg_temp.truth('storage: eight public buckets exist',
    (select count(*) = 8 from storage.buckets where public and id in
      ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages', 'catalog')));
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
