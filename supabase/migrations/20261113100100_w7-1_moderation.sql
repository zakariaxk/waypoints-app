-- W7-1: moderation with one reviewer (SAFE-6, SAFE-7, SAFE-8).
--
-- SAFE-6: anything reported by three different people within 7 days gets
--   hidden_at set and disappears for everyone but its author until reviewed.
-- SAFE-7: profiles.suspended_at. A suspended account cannot insert or update
--   any row (a trigger on every RLS table, plus storage), its profile, cars, and
--   content are hidden from everyone else, and the gateway refuses its tokens.
-- SAFE-8: four service-role functions the reviewer calls from the SQL editor:
--   moderation_hide, moderation_restore, moderation_suspend,
--   moderation_unsuspend. supabase/moderation.sql is the runbook.

set search_path = public, extensions;

-- Columns -------------------------------------------------------------------

alter table public.profiles add column suspended_at timestamptz;
alter table public.profiles add column hidden_at timestamptz;

do $$
declare t text;
begin
  foreach t in array array[
    'posts', 'post_comments', 'messages', 'listings', 'meets', 'reports',
    'teams', 'spots', 'roads', 'cars'
  ] loop
    execute format('alter table public.%I add column hidden_at timestamptz', t);
  end loop;
end $$;

-- Helpers -------------------------------------------------------------------

create function public.is_suspended(who uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.profiles where user_id = who and suspended_at is not null
  );
$$;

-- Visible to the caller: the caller wrote it, or it is neither hidden nor
-- written by a suspended account.
create function public.content_visible(author uuid, hidden timestamptz)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce(author = auth.uid(), false)
      or (hidden is null and not public.is_suspended(author));
$$;

-- Signed in, not blocked by the owner, and the owner is not suspended (the
-- owner always reads their own).
create or replace function public.can_read_profile(owner uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select auth.uid() is not null
     and (
       owner = auth.uid()
       or (
         not public.is_suspended(owner)
         and not exists (
           select 1 from public.blocks
           where blocker_id = owner and blocked_id = auth.uid()
         )
       )
     );
$$;

create or replace function public.post_visible(post uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.posts p
    where p.id = post
      and auth.uid() is not null
      and not public.is_blocked_pair(p.author_id, auth.uid())
      and public.content_visible(p.author_id, p.hidden_at)
  );
$$;

-- Sets or clears hidden_at on the row a content_reports target points at.
-- Returns whether a row matched. Unknown kinds return false.
create function public.set_content_hidden(p_kind text, p_id text, p_hide boolean)
returns boolean
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_table text;
  v_key   text;
  v_type  text;
  v_rows  int;
begin
  select m.t, m.k, m.ty into v_table, v_key, v_type
  from (values
    ('user', 'profiles', 'user_id', 'uuid'),
    ('car', 'cars', 'id', 'uuid'),
    ('post', 'posts', 'id', 'uuid'),
    ('comment', 'post_comments', 'id', 'uuid'),
    ('message', 'messages', 'id', 'bigint'),
    ('listing', 'listings', 'id', 'uuid'),
    ('meet', 'meets', 'id', 'uuid'),
    ('report', 'reports', 'id', 'uuid'),
    ('team', 'teams', 'id', 'uuid'),
    ('spot', 'spots', 'id', 'uuid'),
    ('road', 'roads', 'id', 'uuid')
  ) as m(kind, t, k, ty)
  where m.kind = p_kind;
  if v_table is null then
    return false;
  end if;
  begin
    execute format(
      'update public.%I set hidden_at = %s where %I = cast($1 as %s)',
      v_table,
      case when p_hide then 'coalesce(hidden_at, now())' else 'null' end,
      v_key, v_type
    ) using btrim(p_id);
    get diagnostics v_rows = row_count;
  exception when invalid_text_representation or numeric_value_out_of_range then
    return false;
  end;
  return v_rows > 0;
end;
$$;

-- SAFE-6: three distinct reporters within 7 days hides the target.
create function public.content_reports_auto_hide()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if (
    select count(distinct reporter_id)
    from public.content_reports
    where target_kind = new.target_kind
      and target_id = new.target_id
      and resolved_at is null
      and created_at > now() - interval '7 days'
  ) >= 3 then
    perform public.set_content_hidden(new.target_kind, new.target_id, true);
  end if;
  return null;
end;
$$;

create index content_reports_target_idx
  on public.content_reports (target_kind, target_id, created_at);

create trigger content_reports_auto_hide
  after insert on public.content_reports
  for each row execute function public.content_reports_auto_hide();

-- End users cannot set or clear hidden_at themselves (several of these tables
-- grant update on every column).
create function public.hidden_at_guard()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if pg_trigger_depth() = 1 and public.is_end_user() then
    if tg_op = 'INSERT' then
      new.hidden_at := null;
    elsif new.hidden_at is distinct from old.hidden_at then
      new.hidden_at := old.hidden_at;
    end if;
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'posts', 'post_comments', 'messages', 'listings', 'meets', 'reports',
    'teams', 'spots', 'roads', 'cars'
  ] loop
    execute format(
      'create trigger hidden_at_guard before insert or update on public.%I
         for each row execute function public.hidden_at_guard()', t);
  end loop;
end $$;

-- SAFE-7: a suspended account writes nothing. Only the caller's own top-level
-- statements are checked (pg_trigger_depth() = 1), so cascades from account
-- deletion and work done by other triggers still run. Gateway and service
-- writes carry no auth.uid() and pass.
create function public.suspended_write_guard()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if pg_trigger_depth() = 1
     and auth.uid() is not null
     and public.is_suspended(auth.uid()) then
    raise exception 'This account is suspended' using errcode = 'PT423';
  end if;
  return new;
end;
$$;

do $$
declare t text;
begin
  for t in
    select c.relname
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind = 'r'
      and c.relrowsecurity
  loop
    execute format(
      'create trigger suspended_write_guard before insert or update on public.%I
         for each row execute function public.suspended_write_guard()', t);
  end loop;
end $$;

create policy waypoints_media_not_suspended_insert on storage.objects
  as restrictive for insert to authenticated
  with check (not public.is_suspended(auth.uid()));
create policy waypoints_media_not_suspended_update on storage.objects
  as restrictive for update to authenticated
  using (not public.is_suspended(auth.uid()));

-- Read policies: hidden and suspended content drops out --------------------

drop policy profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to authenticated
  using (public.can_read_profile(user_id) and (user_id = auth.uid() or hidden_at is null));

drop policy cars_read on public.cars;
create policy cars_read on public.cars
  for select to authenticated
  using (public.can_read_profile(owner_id) and (owner_id = auth.uid() or hidden_at is null));

drop policy reports_read on public.reports;
create policy reports_read on public.reports
  for select to authenticated
  using (public.content_visible(author_id, hidden_at));

drop policy meets_read on public.meets;
create policy meets_read on public.meets
  for select to authenticated
  using (
    public.meet_visible(host_id, visibility, team_id)
    and public.content_visible(host_id, hidden_at)
  );

drop policy venue_notes_read on public.venue_notes;
create policy venue_notes_read on public.venue_notes
  for select to authenticated
  using (public.content_visible(author_id, null));

drop policy roads_read on public.roads;
create policy roads_read on public.roads
  for select to authenticated
  using (public.content_visible(author_id, hidden_at));

drop policy spots_read on public.spots;
create policy spots_read on public.spots
  for select to authenticated
  using (public.content_visible(spotter_id, hidden_at));

drop policy teams_read on public.teams;
create policy teams_read on public.teams
  for select to authenticated
  using (
    owner_id = auth.uid()
    or (hidden_at is null and (is_public or public.is_team_member(id)))
  );

drop policy messages_read on public.messages;
create policy messages_read on public.messages
  for select to authenticated
  using (
    public.content_visible(author_id, hidden_at)
    and case when channel_id is not null
      then public.is_team_member(public.channel_team(channel_id))
      else public.thread_open(thread_id)
    end
  );

drop policy posts_read on public.posts;
create policy posts_read on public.posts
  for select to authenticated
  using (
    not public.is_blocked_pair(author_id, auth.uid())
    and public.content_visible(author_id, hidden_at)
  );

drop policy post_comments_read on public.post_comments;
create policy post_comments_read on public.post_comments
  for select to authenticated
  using (public.content_visible(author_id, hidden_at));

drop policy listings_read on public.listings;
create policy listings_read on public.listings
  for select to authenticated
  using (public.content_visible(seller_id, hidden_at));

-- Read RPCs (security definer) apply the same rule -------------------------

create or replace function public.reports_in_bbox(
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
    and public.content_visible(r.author_id, r.hidden_at)
  order by r.created_at desc
  limit 2000;
$$;

create or replace function public.meets_in_bbox(
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
    and public.content_visible(m.host_id, m.hidden_at)
  order by m.starts_at
  limit 500;
$$;

create or replace function public.roads_in_bbox(
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
    and public.content_visible(r.author_id, r.hidden_at)
  group by r.id
  limit 500;
$$;

create or replace function public.venue_notes_near(lng double precision, lat double precision, meters int)
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
    and public.content_visible(v.author_id, null)
  order by st_distance(v.geom, here.g)
  limit 100;
$$;

create or replace function public.hazards_along(path geography, buffer_m int)
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
    and public.content_visible(r.author_id, r.hidden_at)
  order by 9
  limit 1000;
$$;

-- SAFE-8: the reviewer's four functions ------------------------------------

-- Hide a reported thing now and close its open reports.
create function public.moderation_hide(p_kind text, p_target text)
returns text
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not public.set_content_hidden(p_kind, p_target, true) then
    raise exception 'No % with id %', p_kind, p_target using errcode = 'no_data_found';
  end if;
  update public.content_reports r
     set resolved_at = now()
   where r.target_kind = p_kind and lower(r.target_id) = lower(btrim(p_target)) and r.resolved_at is null;
  return format('Hid %s %s', p_kind, p_target);
end;
$$;

-- Show a hidden thing again and close its open reports, so they no longer
-- count toward the three-report rule.
create function public.moderation_restore(p_kind text, p_target text)
returns text
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not public.set_content_hidden(p_kind, p_target, false) then
    raise exception 'No % with id %', p_kind, p_target using errcode = 'no_data_found';
  end if;
  update public.content_reports r
     set resolved_at = now()
   where r.target_kind = p_kind and lower(r.target_id) = lower(btrim(p_target)) and r.resolved_at is null;
  return format('Restored %s %s', p_kind, p_target);
end;
$$;

-- Suspend an account by user id or handle. Its push tokens are dropped; the
-- gateway refuses it within a minute (auth cache).
create function public.moderation_suspend(who text)
returns text
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid;
begin
  select user_id into v_user from public.profiles
   where user_id::text = lower(btrim(who)) or handle::text = lower(btrim(who));
  if v_user is null then
    raise exception 'No account %', who using errcode = 'no_data_found';
  end if;
  update public.profiles set suspended_at = coalesce(suspended_at, now()) where user_id = v_user;
  delete from public.device_tokens where user_id = v_user;
  update public.content_reports
     set resolved_at = now()
   where target_kind = 'user' and lower(target_id) = v_user::text and resolved_at is null;
  return format('Suspended %s', v_user);
end;
$$;

create function public.moderation_unsuspend(who text)
returns text
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid;
begin
  select user_id into v_user from public.profiles
   where user_id::text = lower(btrim(who)) or handle::text = lower(btrim(who));
  if v_user is null then
    raise exception 'No account %', who using errcode = 'no_data_found';
  end if;
  update public.profiles set suspended_at = null where user_id = v_user;
  return format('Unsuspended %s', v_user);
end;
$$;

-- Grants --------------------------------------------------------------------

do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('is_suspended', 'content_visible')
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  for f in
    select p.oid::regprocedure from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('set_content_hidden', 'moderation_hide', 'moderation_restore',
                        'moderation_suspend', 'moderation_unsuspend')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
