-- W11-H follow-up: car_of_week_pool and car_of_week_picks have RLS enabled but were
-- missing suspended_write_guard, breaking the "every RLS table" invariant in
-- checks.sql. The guard only fires for a suspended auth.uid(), so cron and
-- security-definer fills are unaffected.

create trigger suspended_write_guard before insert or update on public.car_of_week_pool
  for each row execute function public.suspended_write_guard();
create trigger suspended_write_guard before insert or update on public.car_of_week_picks
  for each row execute function public.suspended_write_guard();
