-- L59 (SHOW-3): server-side Showdown pair pick.
--
-- The client used to pick pairs over a 300-entry/1000-vote window, so judged pairs
-- past 1000 votes could repeat. showdown_next_pair() does the same pick in SQL: two
-- same-class cars within 150 rating, neither owned by the caller, in a pair the
-- caller has not judged.

create or replace function public.showdown_next_pair(cls public.showdown_class)
returns table (a uuid, b uuid)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select x.car_id, y.car_id
  from public.showdown_entries x
  join public.showdown_entries y
    on y.class = x.class
   and y.car_id > x.car_id
   and abs(x.rating - y.rating) <= 150
  where x.class = showdown_next_pair.cls
    and public.car_owner(x.car_id) is distinct from auth.uid()
    and public.car_owner(y.car_id) is distinct from auth.uid()
    and not exists (
      select 1 from public.showdown_votes v
      where v.voter_id = auth.uid()
        and v.car_lo = x.car_id
        and v.car_hi = y.car_id
    )
  order by random()
  limit 1;
$$;

revoke all on function public.showdown_next_pair(public.showdown_class) from public, anon;
grant execute on function public.showdown_next_pair(public.showdown_class) to authenticated, service_role;
