-- W10-4 (GAR-18): build cost. A timeline entry can carry what it cost, in cents. Only the
-- car's owner may ever read it.
--
-- build_entries_read lets anyone who can read the car select its entries, so the column is
-- closed with a column-level privilege: `authenticated` loses table-wide SELECT and gets
-- SELECT on every column except cost_cents. The owner reads costs through build_costs(car).
-- Consequences: `select *` on build_entries now fails for `authenticated` (clients name
-- their columns), and a column added later must be granted here-style to be readable.

set search_path = public, extensions;

alter table public.build_entries
  add column cost_cents int check (cost_cents >= 0);

revoke select on public.build_entries from authenticated;
grant select (id, car_id, happened_on, title, body, photo_path, mod_id, is_service,
  odometer, odometer_unit, remind_on, created_at)
  on public.build_entries to authenticated;

-- Writing needs no new rule: build_entries_write_own already limits insert and update to
-- the car's owner.

create function public.build_costs(car uuid)
returns table (entry_id uuid, cost_cents int)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select e.id, e.cost_cents
  from public.build_entries e
  where e.car_id = car
    and e.cost_cents is not null
    and public.car_owner(car) = auth.uid();
$$;

revoke execute on function public.build_costs(uuid) from public, anon;
grant execute on function public.build_costs(uuid) to authenticated;
