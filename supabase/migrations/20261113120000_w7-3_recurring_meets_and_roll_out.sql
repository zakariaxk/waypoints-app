-- W7-3: recurring meets (MEET-12) and a cruise destination for "Roll out" (MEET-13).
--
-- recurrence: how the series repeats; null for a one-off. The gateway creates the next
-- occurrence (same series_id, no RSVPs) when one ends, computing the date in time_zone so
-- "every Saturday 8 AM" survives daylight saving. "This and every one after" clears
-- recurrence on the cancelled occurrence and every later one, which ends the series.
-- dest_*: where a cruise rolls out to; the host's "Roll out" starts a convoy with it.

alter table public.meets
  add column recurrence text check (recurrence in ('weekly', 'biweekly', 'monthly')),
  add column series_id  uuid,
  add column time_zone  text check (char_length(time_zone) <= 64),
  add column dest_lat   double precision,
  add column dest_lng   double precision,
  add column dest_name  text check (char_length(dest_name) <= 80),
  add constraint meets_dest_pair check ((dest_lat is null) = (dest_lng is null)),
  add constraint meets_series_pair check (recurrence is null or series_id is not null);

-- Unique so two gateway nodes sweeping at once create one next occurrence, not two.
create unique index meets_series_idx on public.meets (series_id, starts_at);
create index meets_recurring_ends_idx on public.meets (ends_at) where recurrence is not null;
