-- Cleanup audit: close RSVP writes to ended/cancelled meets, give venue_notes
-- and roads the owner update/delete policies they never had, and mark
-- showdown_next_pair volatile (it orders by random(), so `stable` was wrong).

-- An RSVP may only be created or changed while the meet is still open.
drop policy if exists meet_rsvps_insert_own on public.meet_rsvps;
create policy meet_rsvps_insert_own on public.meet_rsvps
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.can_read_meet(meet_id)
    and (car_id is null or public.car_owner(car_id) = auth.uid())
    and exists (select 1 from public.meets m where m.id = meet_id
                and m.cancelled_at is null and m.ends_at > now())
  );
drop policy if exists meet_rsvps_update_own on public.meet_rsvps;
create policy meet_rsvps_update_own on public.meet_rsvps
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and public.can_read_meet(meet_id)
    and (car_id is null or public.car_owner(car_id) = auth.uid())
    and exists (select 1 from public.meets m where m.id = meet_id
                and m.cancelled_at is null and m.ends_at > now())
  );
-- delete_own stays unrestricted: retracting an RSVP must always work.

create policy venue_notes_update_own on public.venue_notes
  for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());
create policy venue_notes_delete_own on public.venue_notes
  for delete to authenticated
  using (author_id = auth.uid());

create policy roads_update_own on public.roads
  for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());
create policy roads_delete_own on public.roads
  for delete to authenticated
  using (author_id = auth.uid());

create or replace function public.showdown_next_pair(cls public.showdown_class)
returns table (a uuid, b uuid)
language sql volatile security definer
set search_path = public, pg_temp
as $$
  select x.car_id, y.car_id
  from public.showdown_entries x
  join public.showdown_entries y
    on y.class = x.class
   and y.car_id > x.car_id
   and abs(x.rating - y.rating) <= 150
  where x.class = showdown_next_pair.cls
    and public.car_owner(x.car_id) is distinct from auth.uid()
    and public.car_owner(y.car_id) is distinct from auth.uid()
    and not exists (
      select 1 from public.showdown_votes v
      where v.voter_id = auth.uid()
        and v.car_lo = x.car_id
        and v.car_hi = y.car_id
    )
  order by random()
  limit 1;
$$;
revoke all on function public.showdown_next_pair(public.showdown_class) from public, anon;
grant execute on function public.showdown_next_pair(public.showdown_class) to authenticated, service_role;

-- Same-class enforcement: the original function never compared the two entries'
-- classes, so a street car could be voted against a hyper car and corrupt both
-- classes' ratings.
create or replace function public.cast_showdown_vote(winner uuid, loser uuid)
returns table (winner_rating int, loser_rating int)
language plpgsql volatile security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_voter uuid := auth.uid();
  v_rw    int;
  v_rl    int;
  v_delta int;
begin
  if v_voter is null then
    raise exception 'Sign in to vote' using errcode = 'insufficient_privilege';
  end if;
  if winner = loser then
    raise exception 'Pick two different cars' using errcode = 'check_violation';
  end if;
  if public.car_owner(winner) = v_voter or public.car_owner(loser) = v_voter then
    raise exception 'You cannot vote on your own car' using errcode = 'insufficient_privilege';
  end if;

  -- Lock both entries in a fixed order so concurrent votes cannot deadlock.
  perform 1 from public.showdown_entries
  where car_id in (winner, loser)
  order by car_id
  for update;

  select rating into v_rw from public.showdown_entries where car_id = winner;
  select rating into v_rl from public.showdown_entries where car_id = loser;
  if v_rw is null or v_rl is null then
    raise exception 'Both cars must be entered in Showdown' using errcode = 'no_data_found';
  end if;
  if (select class from public.showdown_entries where car_id = winner)
     is distinct from (select class from public.showdown_entries where car_id = loser) then
    raise exception 'Both cars must be in the same class' using errcode = 'check_violation';
  end if;

  begin
    insert into public.showdown_votes (voter_id, winner_car_id, loser_car_id)
    values (v_voter, winner, loser);
  exception when unique_violation then
    raise exception 'You already voted on this pair' using errcode = 'unique_violation';
  end;

  v_delta := round(24 * (1 - 1 / (1 + power(10, (v_rl - v_rw) / 400.0))))::int;

  update public.showdown_entries
     set rating = rating + v_delta, wins = wins + 1
   where car_id = winner
  returning rating into v_rw;
  update public.showdown_entries
     set rating = rating - v_delta, losses = losses + 1
   where car_id = loser
  returning rating into v_rl;

  return query select v_rw, v_rl;
end;
$$;
