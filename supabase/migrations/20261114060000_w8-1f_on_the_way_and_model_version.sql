-- W8-1F (NAV-15, STR-10): "on the way" to a meet, and the performance model version of a run.

-- NAV-15: set by the gateway (POST /v1/eta) when someone Going navigates to the meet. A
-- short-lived flag: readers treat it as on only while it is in the future. No position.
alter table public.meet_rsvps
  add column if not exists on_the_way_until timestamptz;

-- Strip ghost versioning: the PerformanceModel version a run was recorded under. Ghosts and
-- friend runs from an older version are hidden from the opponent list, since the same input
-- log no longer replays to the same times. Rows written before this column are version 1.
alter table public.race_results
  add column if not exists model_version int not null default 1 check (model_version >= 1);
create index if not exists race_results_model_version_idx on public.race_results (model_version);
