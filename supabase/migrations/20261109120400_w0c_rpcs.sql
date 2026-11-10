-- W0-C: RPCs (plan 5.3, 5.4, 5.5).
-- Read RPCs are security definer and stable; they apply the same visibility
-- rules as the RLS policies and return latitude/longitude (or GeoJSON for lines) rather
-- than raw geography so clients need no WKB decoding.

set search_path = public, extensions;

create function public.reports_in_bbox(
  min_lng double precision, min_lat double precision,
  max_lng double precision, max_lat double precision
)
returns table (
  id uuid, author_id uuid, kind public.report_kind,
  latitude double precision, longitude double precision,
  note text, confirmations int, expires_at timestamptz, permanent boolean,
  created_at timestamptz
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select r.id, r.author_id, r.kind,
         st_y(r.geom::geometry), st_x(r.geom::geometry),
         r.note, r.confirmations, r.expires_at, r.permanent, r.created_at
  from public.reports r
  where auth.uid() is not null
    and r.geom && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
    and (r.permanent or r.expires_at > now())
  order by r.created_at desc
  limit 2000;
$$;

-- Only meets ending in the future, not cancelled, visible to the caller.
create function public.meets_in_bbox(
  min_lng double precision, min_lat double precision,
  max_lng double precision, max_lat double precision
)
returns table (
  id uuid, host_id uuid, title text, kind public.meet_kind,
  latitude double precision, longitude double precision, place_name text,
  starts_at timestamptz, ends_at timestamptz,
  visibility public.meet_visibility, team_id uuid, going_count int
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select m.id, m.host_id, m.title, m.kind,
         st_y(m.geom::geometry), st_x(m.geom::geometry), m.place_name,
         m.starts_at, m.ends_at, m.visibility, m.team_id,
         (select count(*)::int from public.meet_rsvps v
           where v.meet_id = m.id and v.status = 'going')
  from public.meets m
  where m.geom && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
    and m.ends_at > now()
    and m.cancelled_at is null
    and public.meet_visible(m.host_id, m.visibility, m.team_id)
  order by m.starts_at
  limit 500;
$$;

create function public.roads_in_bbox(
  min_lng double precision, min_lat double precision,
  max_lng double precision, max_lat double precision
)
returns table (
  id uuid, author_id uuid, name text, length_m int, path_geojson text,
  surface_avg numeric, scenery_avg numeric, traffic_avg numeric, rating_count int,
  created_at timestamptz
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select r.id, r.author_id, r.name, r.length_m, st_asgeojson(r.path, 6),
         round(avg(rr.surface), 1), round(avg(rr.scenery), 1), round(avg(rr.traffic), 1),
         count(rr.user_id)::int, r.created_at
  from public.roads r
  left join public.road_ratings rr on rr.road_id = r.id
  where auth.uid() is not null
    and r.path && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
  group by r.id
  limit 500;
$$;

create function public.venue_notes_near(lng double precision, lat double precision, meters int)
returns table (
  id uuid, author_id uuid, latitude double precision, longitude double precision,
  entrance public.entrance_grade, lot_size public.lot_size, lit boolean, note text,
  distance_m int, created_at timestamptz
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with here as (
    select st_setsrid(st_makepoint(lng, lat), 4326)::geography as g
  )
  select v.id, v.author_id, st_y(v.geom::geometry), st_x(v.geom::geometry),
         v.entrance, v.lot_size, v.lit, v.note,
         round(st_distance(v.geom, here.g))::int, v.created_at
  from public.venue_notes v, here
  where auth.uid() is not null
    and st_dwithin(v.geom, here.g, least(greatest(meters, 1), 50000))
  order by st_distance(v.geom, here.g)
  limit 100;
$$;

-- Active reports within buffer_m of a route, ordered by distance along it.
-- path is accepted as WKT/EWKT, e.g. 'SRID=4326;LINESTRING(lng lat, ...)'.
create function public.hazards_along(path geography, buffer_m int)
returns table (
  id uuid, kind public.report_kind, latitude double precision, longitude double precision,
  note text, confirmations int, expires_at timestamptz, permanent boolean,
  along_m int, offset_m int
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select r.id, r.kind, st_y(r.geom::geometry), st_x(r.geom::geometry),
         r.note, r.confirmations, r.expires_at, r.permanent,
         round(st_linelocatepoint(path::geometry, r.geom::geometry) * st_length(path))::int,
         round(st_distance(r.geom, path))::int
  from public.reports r
  where auth.uid() is not null
    and st_dwithin(r.geom, path, least(greatest(buffer_m, 1), 500))
    and (r.permanent or r.expires_at > now())
  order by 9
  limit 1000;
$$;

-- Join a team with its invite code (works for private teams). Returns the team id.
create function public.join_team(code text)
returns uuid
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_team uuid;
begin
  if auth.uid() is null then
    raise exception 'Sign in to join a team' using errcode = 'insufficient_privilege';
  end if;
  select id into v_team from public.teams where invite_code = btrim(code);
  if v_team is null then
    raise exception 'That invite code does not match a team' using errcode = 'no_data_found';
  end if;
  insert into public.team_members (team_id, user_id)
  values (v_team, auth.uid())
  on conflict (team_id, user_id) do nothing;
  return v_team;
end;
$$;

-- Showdown vote with Elo, K = 24. Rejects the voter's own cars and repeat pairs.
create function public.cast_showdown_vote(winner uuid, loser uuid)
returns table (winner_rating int, loser_rating int)
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_voter uuid := auth.uid();
  v_rw    int;
  v_rl    int;
  v_delta int;
begin
  if v_voter is null then
    raise exception 'Sign in to vote' using errcode = 'insufficient_privilege';
  end if;
  if winner = loser then
    raise exception 'Pick two different cars' using errcode = 'check_violation';
  end if;
  if public.car_owner(winner) = v_voter or public.car_owner(loser) = v_voter then
    raise exception 'You cannot vote on your own car' using errcode = 'insufficient_privilege';
  end if;

  -- Lock both entries in a fixed order so concurrent votes cannot deadlock.
  perform 1 from public.showdown_entries
  where car_id in (winner, loser)
  order by car_id
  for update;

  select rating into v_rw from public.showdown_entries where car_id = winner;
  select rating into v_rl from public.showdown_entries where car_id = loser;
  if v_rw is null or v_rl is null then
    raise exception 'Both cars must be entered in Showdown' using errcode = 'no_data_found';
  end if;

  begin
    insert into public.showdown_votes (voter_id, winner_car_id, loser_car_id)
    values (v_voter, winner, loser);
  exception when unique_violation then
    raise exception 'You already voted on this pair' using errcode = 'unique_violation';
  end;

  v_delta := round(24 * (1 - 1 / (1 + power(10, (v_rl - v_rw) / 400.0))))::int;

  update public.showdown_entries
     set rating = rating + v_delta, wins = wins + 1
   where car_id = winner
  returning rating into v_rw;
  update public.showdown_entries
     set rating = rating - v_delta, losses = losses + 1
   where car_id = loser
  returning rating into v_rl;

  return query select v_rw, v_rl;
end;
$$;

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'reports_in_bbox', 'meets_in_bbox', 'roads_in_bbox', 'venue_notes_near',
        'hazards_along', 'join_team', 'cast_showdown_vote'
      )
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
