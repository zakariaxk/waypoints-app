-- L78 (GAR-19): planned entries. A timeline entry can be marked planned; planned entries sit
-- ahead on the owner's timeline with a Planned mark and no date. Marking one done stamps today
-- (the client updates is_planned and happened_on through the existing write policy). The owner
-- alone sees a planned-cost subtotal; visitors never see planned entries or their cost.
--
-- Cost was closed column-wise in W10-4; planned entries hide whole rows, so the read policy
-- gets the predicate: anyone who can read the car sees non-planned entries, planned ones only
-- the owner. build_costs already returns nothing for non-owners, so a planned cost never leaks.

set search_path = public, extensions;

alter table public.build_entries
  add column is_planned boolean not null default false;

drop policy build_entries_read on public.build_entries;
create policy build_entries_read on public.build_entries
  for select to authenticated
  using (public.can_read_car(car_id)
         and (not is_planned or public.car_owner(car_id) = auth.uid()));

-- W10-4 revoked table-wide SELECT in favour of a column list; add the new column so clients
-- can read it (cost_cents stays ungranted).
grant select (is_planned) on public.build_entries to authenticated;

-- Writing needs no new rule: build_entries_write_own already limits insert and update to the
-- car's owner.
