-- W10-6 (STR-11): car of the week.
--
-- Every Monday 00:00 UTC one catalog car, stock, is the same for everyone. The pick comes
-- from car_of_week_pool, a curated list of catalog variant ids whose specs come from
-- tools/catalog/overrides.csv (the rows the model is checked against in ReferenceCars).
-- car_of_week_pick() is the scheduled fill (pg_cron, like SHOW-7's weekly close); it only
-- inserts the row for the week that just started, so the pick is frozen for the week even
-- if the pool changes later. car_of_week() answers for the current week and falls back to
-- the same deterministic index when the cron run was missed, so a pick always exists.
--
-- Runs go to car_of_week_runs: one row per attempt, stamped server-side with the current
-- week and this week's variant by car_of_week_save(). car_of_week_board() lists each
-- driver's best run this week for the caller, their friends, and their teammates, with
-- the same visibility rules as everywhere else (blocks and suspension respected).
-- Nothing is awarded; the list resets weekly.
--
-- pg_cron must be enabled on the Supabase project; if it is not available when this
-- migration runs, the functions still work and a notice asks for the schedule by hand.

create table public.car_of_week_pool (
  variant_id bigint primary key,
  label      text not null
);

insert into public.car_of_week_pool (variant_id, label) values
  (973990659323, '2026 Mazda MX-5 RF Club'),
  (264824251171, '2020 Toyota 86'),
  (502976233635, '2018 Ford Fiesta ST'),
  (964981987224, '2017 Ford Focus ST'),
  (741216039861, '2020 Subaru WRX STI'),
  (350041809757, '2020 Nissan 370Z'),
  (184776906406, '2025 Honda Civic Type R'),
  (800349239308, '2026 Volkswagen Golf R'),
  (77429111588,  '2021 Chevrolet Camaro 1SS'),
  (511603918804, '2024 BMW M3 CS'),
  (720186869195, '2022 Porsche 718 Cayman GT4'),
  (506733269715, '2021 Porsche 911 Carrera S'),
  (652529291189, '2025 Toyota Supra 3.0'),
  (949491379732, '2021 Ford Mustang Shelby GT500'),
  (1000433778671,'2019 Nissan GT-R'),
  (746633813229, '2013 BMW M3 Coupe'),
  (80803697858,  '2012 Chevrolet Camaro ZL1'),
  (776468431694, '2023 Dodge Charger Scat Pack');

alter table public.car_of_week_pool enable row level security;
revoke all on public.car_of_week_pool from anon, authenticated;

create table public.car_of_week_picks (
  week_start date primary key,          -- the Monday the week starts on (UTC)
  variant_id bigint not null,
  label      text not null
);

alter table public.car_of_week_picks enable row level security;
revoke all on public.car_of_week_picks from anon, authenticated;

create table public.car_of_week_runs (
  user_id       uuid not null references public.profiles (user_id) on delete cascade,
  week_start    date not null,
  variant_id    bigint not null,
  et_ms         int not null check (et_ms between 4000 and 60000),
  trap_mph_x10  int check (trap_mph_x10 >= 0),
  reaction_ms   int check (reaction_ms >= 0),
  model_version int not null default 1 check (model_version >= 1),
  created_at    timestamptz not null default now()
);
create index car_of_week_runs_week_idx on public.car_of_week_runs (week_start, et_ms);

alter table public.car_of_week_runs enable row level security;
-- Reads and writes go through the security-definer functions only, so the week's
-- stamp and the board's visibility rules cannot be bypassed.
revoke all on public.car_of_week_runs from anon, authenticated;

create trigger suspended_write_guard before insert or update on public.car_of_week_runs
  for each row execute function public.suspended_write_guard();

-- This week's pick row if the cron filled it, else the deterministic fallback: pool
-- index = weeks since the epoch modulo the pool size. Same answer either way.
create function public.car_of_week_current()
returns table (week_start date, variant_id bigint, label text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with w as (
    select (date_trunc('week', now() at time zone 'utc'))::date as s
  ),
  idx as (
    select w.s,
           mod(floor(extract(epoch from w.s::timestamp) / 604800)::bigint,
               (select count(*) from public.car_of_week_pool))::int as i
    from w
  )
  select coalesce(p.week_start, i.s), coalesce(p.variant_id, pool.variant_id),
         coalesce(p.label, pool.label)
  from idx i
  left join public.car_of_week_picks p on p.week_start = i.s
  join lateral (
    select variant_id, label from public.car_of_week_pool
    order by variant_id offset i.i limit 1
  ) pool on true;
$$;

create function public.car_of_week()
returns table (week_start date, variant_id bigint, label text)
language sql stable security definer
set search_path = public, pg_temp
as $$
  select * from public.car_of_week_current();
$$;

-- The scheduled fill, Monday 00:00 UTC. Fills only the current week; idempotent.
create function public.car_of_week_pick()
returns void
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  c record;
begin
  select * into c from public.car_of_week_current();
  insert into public.car_of_week_picks (week_start, variant_id, label)
  values (c.week_start, c.variant_id, c.label)
  on conflict (week_start) do nothing;
end;
$$;

-- Friends and teammates: accepted friendships either way, or a shared team.
create function public.shares_team(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  -- Like are_friends/is_blocked_pair: only answers when the caller is one of the pair
  -- (or there is no caller: the gateway, triggers).
  select (auth.uid() is null or auth.uid() in (a, b))
     and a is not null and b is not null
     and exists (
    select 1
    from public.team_members ma
    join public.team_members mb on mb.team_id = ma.team_id and mb.user_id = b
    where ma.user_id = a
  );
$$;

-- Records a run in this week's car. The week and variant are stamped here, never taken
-- from the caller; the table check and the write guard still apply.
create function public.car_of_week_save(
  p_et_ms int,
  p_trap_mph_x10 int default null,
  p_reaction_ms int default null,
  p_model_version int default 1
)
returns void
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  c record;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  if p_et_ms not between 4000 and 60000 then
    raise exception 'et_ms out of range' using errcode = '22023';
  end if;
  select * into c from public.car_of_week_current();
  insert into public.car_of_week_runs
    (user_id, week_start, variant_id, et_ms, trap_mph_x10, reaction_ms, model_version)
  values
    (auth.uid(), c.week_start, c.variant_id, p_et_ms, p_trap_mph_x10, p_reaction_ms,
     greatest(coalesce(p_model_version, 1), 1));
end;
$$;

-- This week's board: each driver's best run, fastest first. Only the caller,
-- their friends, and their teammates; blocked and suspended accounts drop out.
create function public.car_of_week_board()
returns table (
  user_id uuid,
  display_name text,
  et_ms int,
  trap_mph_x10 int,
  reaction_ms int,
  model_version int,
  created_at timestamptz
)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with w as (
    select (date_trunc('week', now() at time zone 'utc'))::date as s
  ),
  best as (
    select distinct on (r.user_id)
           r.user_id, r.et_ms, r.trap_mph_x10, r.reaction_ms, r.model_version, r.created_at
    from public.car_of_week_runs r
    join w on r.week_start = w.s
    order by r.user_id, r.et_ms asc, r.created_at asc
  )
  select b.user_id, p.display_name, b.et_ms, b.trap_mph_x10, b.reaction_ms,
         b.model_version, b.created_at
  from best b
  join public.profiles p on p.user_id = b.user_id
  where public.content_visible(b.user_id, p.hidden_at)
    and not public.is_blocked_pair(auth.uid(), b.user_id)
    and (b.user_id = auth.uid()
         or public.are_friends(auth.uid(), b.user_id)
         or public.shares_team(auth.uid(), b.user_id))
  order by b.et_ms asc, b.user_id
  limit 100;
$$;

revoke all on function public.car_of_week_current() from public, anon;
grant execute on function public.car_of_week_current() to authenticated, service_role;
revoke all on function public.car_of_week() from public, anon;
grant execute on function public.car_of_week() to authenticated, service_role;
revoke all on function public.car_of_week_pick() from public, anon, authenticated;
grant execute on function public.car_of_week_pick() to service_role;
revoke all on function public.shares_team(uuid, uuid) from public, anon;
grant execute on function public.shares_team(uuid, uuid) to authenticated, service_role;
revoke all on function public.car_of_week_save(int, int, int, int) from public, anon;
grant execute on function public.car_of_week_save(int, int, int, int) to authenticated, service_role;
revoke all on function public.car_of_week_board() from public, anon;
grant execute on function public.car_of_week_board() to authenticated, service_role;

-- Fill this week now so the first clients never hit the fallback path, then schedule
-- the weekly fill for Monday 00:00 UTC (pg_cron runs in UTC).
select public.car_of_week_pick();

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'car-of-week-pick') then
      perform cron.unschedule('car-of-week-pick');
    end if;
    perform cron.schedule('car-of-week-pick', '0 0 * * 1', 'select public.car_of_week_pick()');
  else
    raise notice 'pg_cron is not available: enable it, then run cron.schedule(''car-of-week-pick'', ''0 0 * * 1'', ''select public.car_of_week_pick()'')';
  end if;
end $$;
