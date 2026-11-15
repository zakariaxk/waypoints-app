-- W11-H part 2: objects created by w10-6 / w10-8 sort after w11-h_database.sql, so the
-- hardening that touches them lives here, after both exist.
--
-- 1. car_of_week_runs has no primary key and no user_id index: deleting a profile
--    cascades through a sequential scan. Same for message_reactions, whose primary key
--    leads with message_id.
-- 2. car_of_week_runs columns the save RPC does not range-check get the same caps the
--    client already applies to race_results.

set search_path = public, extensions;

create index if not exists car_of_week_runs_user_idx on public.car_of_week_runs (user_id);
create index if not exists message_reactions_user_idx on public.message_reactions (user_id);

alter table public.car_of_week_runs
  add constraint car_of_week_runs_trap_max check (trap_mph_x10 is null or trap_mph_x10 <= 10000) not valid;
alter table public.car_of_week_runs validate constraint car_of_week_runs_trap_max;
alter table public.car_of_week_runs
  add constraint car_of_week_runs_reaction_max check (reaction_ms is null or reaction_ms <= 60000) not valid;
alter table public.car_of_week_runs validate constraint car_of_week_runs_reaction_max;
alter table public.car_of_week_runs
  add constraint car_of_week_runs_model_max check (model_version <= 100) not valid;
alter table public.car_of_week_runs validate constraint car_of_week_runs_model_max;
