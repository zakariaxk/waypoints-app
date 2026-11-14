-- W8-1A: a saved road for a cruise (MEET-13) and people's choice (MEET-14).
--
-- road_id: the saved road a cruise drives; "Roll out" starts the convoy on its path.
-- meet_votes: during a meet or show, each checked-in person picks one car brought to it
-- (a Going RSVP's car). The gateway's meet-choice sweep calls settle_peoples_choice() each
-- minute: for every ended meet with votes and no result yet it sets winner_car_id and adds a
-- line to the winning car's build timeline.

alter table public.meets
  add column road_id           uuid references public.roads (id) on delete set null,
  add column winner_car_id     uuid references public.cars (id) on delete set null,
  add column choice_settled_at timestamptz;

create table public.meet_votes (
  meet_id    uuid not null references public.meets (id) on delete cascade,
  voter_id   uuid not null references public.profiles (user_id) on delete cascade,
  car_id     uuid not null references public.cars (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (meet_id, voter_id)
);
create index meet_votes_car_idx on public.meet_votes (meet_id, car_id);

-- The caller may pick this car at this meet now: a meet or show that is on, the caller
-- checked in, and the car brought by someone Going.
create function public.can_pick_car(p_meet uuid, p_car uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.meets m
    where m.id = p_meet and m.kind in ('meet', 'show') and m.cancelled_at is null
      and m.starts_at <= now() and m.ends_at > now()
  )
  and exists (select 1 from public.meet_checkins c where c.meet_id = p_meet and c.user_id = auth.uid())
  and exists (select 1 from public.meet_rsvps r where r.meet_id = p_meet and r.status = 'going' and r.car_id = p_car);
$$;

alter table public.meet_votes enable row level security;
create policy meet_votes_read on public.meet_votes
  for select to authenticated
  using (public.can_read_meet(meet_id));
create policy meet_votes_insert_own on public.meet_votes
  for insert to authenticated
  with check (voter_id = auth.uid() and public.can_pick_car(meet_id, car_id));
create policy meet_votes_update_own on public.meet_votes
  for update to authenticated
  using (voter_id = auth.uid())
  with check (voter_id = auth.uid() and public.can_pick_car(meet_id, car_id));
create policy meet_votes_delete_own on public.meet_votes
  for delete to authenticated
  using (voter_id = auth.uid() and public.can_pick_car(meet_id, car_id));
revoke all on public.meet_votes from anon;
grant select, insert, delete on public.meet_votes to authenticated;
grant update (car_id) on public.meet_votes to authenticated;

-- Settles every ended meet or show with votes: most votes wins, ties go to the car picked
-- first. Returns how many meets were settled. Gateway only.
create function public.settle_peoples_choice()
returns int
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r record;
  v_winner uuid;
  v_votes int;
  n int := 0;
begin
  for r in
    select m.id, m.title, m.ends_at from public.meets m
    where m.ends_at <= now() and m.choice_settled_at is null and m.kind in ('meet', 'show')
      and exists (select 1 from public.meet_votes v where v.meet_id = m.id)
    order by m.ends_at
    limit 100
    for update skip locked
  loop
    select v.car_id, count(*) into v_winner, v_votes
    from public.meet_votes v
    where v.meet_id = r.id
    group by v.car_id
    order by count(*) desc, min(v.created_at)
    limit 1;
    update public.meets set winner_car_id = v_winner, choice_settled_at = now() where id = r.id;
    if v_winner is not null then
      insert into public.build_entries (car_id, happened_on, title, body)
      values (v_winner, r.ends_at::date, left('People''s choice at ' || r.title, 60),
              case when v_votes = 1 then '1 vote.' else v_votes || ' votes.' end);
    end if;
    n := n + 1;
  end loop;
  return n;
end; $$;
revoke all on function public.settle_peoples_choice() from public, anon, authenticated;
