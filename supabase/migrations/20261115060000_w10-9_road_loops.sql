-- W10-9 (ROAD-6): loops. Saved roads grouped in driving order under a name. The order is the
-- array order, so a reorder is one update. Road ids are not foreign keys: a road that is gone
-- or hidden simply drops out when the client loads the loop's roads through roads_read.
--
-- Access: a loop is private to its owner (RLS: owner only, every verb). A share link carries
-- the id; road_loop(p_id) returns that one loop to any signed-in caller who has it, unless the
-- owner is suspended or the two have blocked each other. Nobody can list another person's loops.

set search_path = public, extensions;

create table public.road_loops (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles (user_id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 50),
  road_ids   uuid[] not null check (cardinality(road_ids) between 1 and 20),
  created_at timestamptz not null default now()
);
create index road_loops_owner_idx on public.road_loops (owner_id);

alter table public.road_loops enable row level security;
revoke all on public.road_loops from anon;

create trigger suspended_write_guard before insert or update on public.road_loops
  for each row execute function public.suspended_write_guard();

create policy road_loops_read_own on public.road_loops
  for select to authenticated
  using (owner_id = auth.uid());
create policy road_loops_insert_own on public.road_loops
  for insert to authenticated
  with check (owner_id = auth.uid());
create policy road_loops_update_own on public.road_loops
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());
create policy road_loops_delete_own on public.road_loops
  for delete to authenticated
  using (owner_id = auth.uid());

-- The share link: one loop, by id.
create function public.road_loop(p_id uuid)
returns setof public.road_loops
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select l.*
  from public.road_loops l
  where l.id = p_id
    and auth.uid() is not null
    and (
      l.owner_id = auth.uid()
      or (not public.is_suspended(l.owner_id) and not public.is_blocked_pair(l.owner_id, auth.uid()))
    );
$$;

revoke execute on function public.road_loop(uuid) from public, anon;
grant execute on function public.road_loop(uuid) to authenticated;
