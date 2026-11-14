-- W6-8 (SHOW-6, SHOW-7): the Showdown week.
--
-- A week runs from Monday 00:00 UTC to the next Monday 00:00 UTC. A car's weekly score is the
-- number of votes it won in that window; ties break by rating, then car id. showdown_week_top()
-- is that definition, used both by the app's "This week" rankings and by the weekly close, which
-- awards showdown_top10 to the owners of the top 10 cars of each class.
--
-- The close is scheduled with pg_cron. pg_cron must be enabled on the Supabase project
-- (Dashboard > Database > Extensions > pg_cron). If it is not available when this migration runs,
-- the functions are still created and a notice is raised; enable pg_cron and run the
-- cron.schedule call at the bottom by hand.

create or replace function public.showdown_week_top(
  cls public.showdown_class,
  week_start timestamptz default null,
  lim int default 50
)
returns table (car_id uuid, week_wins int)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with bounds as (
    select coalesce(showdown_week_top.week_start,
                    date_trunc('week', now() at time zone 'utc') at time zone 'utc') as s
  )
  select e.car_id, count(*)::int as week_wins
  from public.showdown_votes v
  join public.showdown_entries e on e.car_id = v.winner_car_id
  cross join bounds b
  where e.class = showdown_week_top.cls
    and v.created_at >= b.s
    and v.created_at < b.s + interval '7 days'
  group by e.car_id, e.rating
  order by count(*) desc, e.rating desc, e.car_id
  limit least(greatest(coalesce(showdown_week_top.lim, 50), 1), 100);
$$;

-- Closes the week that started at week_start (default: the week that just ended) and returns
-- how many owners were awarded. Awards are idempotent (public.award ignores repeats).
create or replace function public.showdown_close_week(week_start timestamptz default null)
returns int
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_start timestamptz := coalesce(
    showdown_close_week.week_start,
    (date_trunc('week', now() at time zone 'utc') at time zone 'utc') - interval '7 days'
  );
  v_count int := 0;
  r record;
begin
  for r in
    select distinct c.owner_id
    from unnest(enum_range(null::public.showdown_class)) as k(cls)
    cross join lateral public.showdown_week_top(k.cls, v_start, 10) t
    join public.cars c on c.id = t.car_id
  loop
    perform public.award(r.owner_id, 'showdown_top10');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.showdown_week_top(public.showdown_class, timestamptz, int) from public, anon;
grant execute on function public.showdown_week_top(public.showdown_class, timestamptz, int) to authenticated, service_role;
revoke all on function public.showdown_close_week(timestamptz) from public, anon, authenticated;
grant execute on function public.showdown_close_week(timestamptz) to service_role;

-- Monday 00:00 UTC (pg_cron runs in UTC).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'showdown-close-week') then
      perform cron.unschedule('showdown-close-week');
    end if;
    perform cron.schedule('showdown-close-week', '0 0 * * 1', 'select public.showdown_close_week()');
  else
    raise notice 'pg_cron is not available: enable it, then run cron.schedule(''showdown-close-week'', ''0 0 * * 1'', ''select public.showdown_close_week()'')';
  end if;
end $$;
