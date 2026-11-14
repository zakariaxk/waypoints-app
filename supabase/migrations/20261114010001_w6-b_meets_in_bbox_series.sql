-- W6-B (MEET-12, MEET-13): meets_in_bbox predates the W7-3 columns, so map pins lost their
-- recurrence and roll-out destination (Backend's MeetRow reads them). Same function and the
-- same W7-1 moderation filter, plus details, recurrence, series_id, and dest_*. The return
-- type changes, so the function is dropped and created again.

set search_path = public, extensions;

drop function if exists public.meets_in_bbox(double precision, double precision, double precision, double precision);

create function public.meets_in_bbox(
  min_lng double precision, min_lat double precision,
  max_lng double precision, max_lat double precision
)
returns table (
  id uuid, host_id uuid, title text, kind public.meet_kind,
  latitude double precision, longitude double precision, place_name text,
  starts_at timestamptz, ends_at timestamptz,
  visibility public.meet_visibility, team_id uuid, going_count int,
  details text, recurrence text, series_id uuid,
  dest_lat double precision, dest_lng double precision, dest_name text
)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select m.id, m.host_id, m.title, m.kind,
         st_y(m.geom::geometry), st_x(m.geom::geometry), m.place_name,
         m.starts_at, m.ends_at, m.visibility, m.team_id,
         (select count(*)::int from public.meet_rsvps v
           where v.meet_id = m.id and v.status = 'going'),
         m.details, m.recurrence, m.series_id,
         m.dest_lat, m.dest_lng, m.dest_name
  from public.meets m
  where m.geom && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
    and m.ends_at > now()
    and m.cancelled_at is null
    and public.meet_visible(m.host_id, m.visibility, m.team_id)
    and public.content_visible(m.host_id, m.hidden_at)
  order by m.starts_at
  limit 500;
$$;

revoke execute on function public.meets_in_bbox(double precision, double precision, double precision, double precision)
  from public, anon;
grant execute on function public.meets_in_bbox(double precision, double precision, double precision, double precision)
  to authenticated, service_role;
