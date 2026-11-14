-- W6-B (SAFE-7, SEC-1): moderation coverage for every table and read RPC added after
-- 20261113100100_w7-1_moderation.sql, and grants tightened on tables added since W0-C.
--
-- 1. suspended_write_guard on every RLS table that does not have it yet (help_requests,
--    help_responses, notifications). Gateway writes carry no auth.uid() and still pass.
-- 2. Read policies drop rows written by suspended accounts (content_visible), as W7-1 did for
--    the W0-C tables: help requests and responses, notifications by actor, meet check-ins.
-- 3. showdown_week_top is security definer: hidden cars and cars of suspended owners drop out,
--    so the weekly close never awards them either.
-- 4. moderation_suspend also ends the account's active help requests and sends
--    pg_notify('waypoints_suspended', <user id>); the gateway re-checks open connections
--    every 30 s and closes a suspended account's with reason "suspended".
-- 5. Supabase's default privileges grant every new table to anon and authenticated; RLS keeps
--    them out, but the grants are trimmed to what each access rule needs (plan section 5).

set search_path = public, extensions;

-- 1. Write guard ---------------------------------------------------------------

do $$
declare t text;
begin
  for t in
    select c.relname
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind = 'r'
      and c.relrowsecurity
      and not exists (
        select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'suspended_write_guard')
  loop
    execute format(
      'create trigger suspended_write_guard before insert or update on public.%I
         for each row execute function public.suspended_write_guard()', t);
  end loop;
end $$;

-- 2. Read policies -------------------------------------------------------------

drop policy help_requests_read on public.help_requests;
create policy help_requests_read on public.help_requests for select to authenticated
  using (
    public.can_read_help(requester_id)
    and public.content_visible(requester_id, null)
    and (requester_id = auth.uid() or (ended_at is null and expires_at > now()))
  );

drop policy help_responses_read on public.help_responses;
create policy help_responses_read on public.help_responses for select to authenticated
  using (
    public.content_visible(user_id, null)
    and (user_id = auth.uid()
         or exists (select 1 from public.help_requests h
                    where h.id = request_id and h.requester_id = auth.uid()))
  );

drop policy notifications_owner_read on public.notifications;
create policy notifications_owner_read on public.notifications
  for select to authenticated
  using (user_id = auth.uid() and public.content_visible(actor_id, null));

drop policy meet_checkins_read on public.meet_checkins;
create policy meet_checkins_read on public.meet_checkins for select to authenticated
  using (public.can_read_meet(meet_id) and public.content_visible(user_id, null));

-- 3. showdown_week_top ---------------------------------------------------------

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
  join public.cars c on c.id = e.car_id
  cross join bounds b
  where e.class = showdown_week_top.cls
    and v.created_at >= b.s
    and v.created_at < b.s + interval '7 days'
    and c.hidden_at is null
    and not public.is_suspended(c.owner_id)
  group by e.car_id, e.rating
  order by count(*) desc, e.rating desc, e.car_id
  limit least(greatest(coalesce(showdown_week_top.lim, 50), 1), 100);
$$;

revoke all on function public.showdown_week_top(public.showdown_class, timestamptz, int) from public, anon;
grant execute on function public.showdown_week_top(public.showdown_class, timestamptz, int) to authenticated, service_role;

-- 4. moderation_suspend --------------------------------------------------------

create or replace function public.moderation_suspend(who text)
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
  update public.help_requests set ended_at = now() where requester_id = v_user and ended_at is null;
  update public.content_reports
     set resolved_at = now()
   where target_kind = 'user' and lower(target_id) = v_user::text and resolved_at is null;
  perform pg_notify('waypoints_suspended', v_user::text);
  return format('Suspended %s', v_user);
end;
$$;

revoke execute on function public.moderation_suspend(text) from public, anon, authenticated;
grant execute on function public.moderation_suspend(text) to service_role;

-- 5. Grants --------------------------------------------------------------------

revoke all on public.convoys, public.notification_prefs, public.meet_checkins,
  public.help_requests, public.help_responses, public.notifications from anon;

revoke insert, update, delete on public.meet_checkins from authenticated;

-- Revoking table-level update also drops column grants, so read_at is granted again.
revoke insert, update, delete on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;

-- SAFE-9 counts run in Postgres (gateway): help requests a day, map reports in 10 minutes.
create index if not exists help_requests_requester_created_idx
  on public.help_requests (requester_id, created_at);
create index if not exists report_votes_user_created_idx
  on public.report_votes (user_id, created_at);
