-- W10-2 (PRD MEET-15): a meet can be capped at a number of cars. Going past the cap joins a
-- waitlist in arrival order; when a seat frees, the first waiting person becomes Going and is
-- told once.
--
-- RSVPs are still written by the client straight to meet_rsvps. The triggers below decide the
-- seat, so the client keeps sending 'going' and reads back 'going' or 'waitlist'. Every
-- decision holds a row lock on the meet, so two people cannot take the last seat and a freed
-- seat goes to exactly one person.
--
-- The new enum value appears only inside plpgsql bodies here: it cannot be used by a statement
-- in the transaction that adds it.

alter type public.rsvp_status add value if not exists 'waitlist';

alter table public.meets
  add column capacity int check (capacity between 1 and 999);

-- When this person joined the waitlist: the order of the line. Set only by the trigger.
alter table public.meet_rsvps
  add column waitlisted_at timestamptz;

-- Promotions the gateway has yet to push (its meet-waitlist sweep deletes each row as it
-- sends). The Activity row is written by promote_waitlist itself; this is only the push.
create table public.meet_promotions (
  meet_id uuid not null references public.meets (id) on delete cascade,
  user_id uuid not null references public.profiles (user_id) on delete cascade,
  primary key (meet_id, user_id)
);
alter table public.meet_promotions enable row level security;
revoke all on public.meet_promotions from anon, authenticated;
create trigger suspended_write_guard before insert or update on public.meet_promotions
  for each row execute function public.suspended_write_guard();

-- Seats the first people waiting while there is room (all of them when the cap is removed).
create function public.promote_waitlist(p_meet uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  m record;
  w uuid;
begin
  select host_id, title, capacity into m from public.meets
   where id = p_meet and cancelled_at is null and ends_at > now()
     for no key update;
  if not found then
    return;
  end if;
  loop
    exit when m.capacity is not null and m.capacity <=
      (select count(*) from public.meet_rsvps where meet_id = p_meet and status = 'going');
    select user_id into w from public.meet_rsvps
     where meet_id = p_meet and status = 'waitlist'
     order by waitlisted_at, user_id limit 1;
    exit when not found;
    update public.meet_rsvps set status = 'going' where meet_id = p_meet and user_id = w;
    if public.record_notification(w, 'meet_changed', m.host_id, 'waypoints://meet/' || p_meet,
         m.title, 'A spot opened up. You''re going.', 'meet_spot:' || p_meet) then
      insert into public.meet_promotions (meet_id, user_id) values (p_meet, w)
      on conflict do nothing;
    end if;
  end loop;
end;
$$;
revoke all on function public.promote_waitlist(uuid) from public, anon, authenticated;

-- Going or waitlist is decided here, whatever the client sent. Someone already Going keeps
-- the seat (a lowered cap bumps nobody); someone waiting keeps their place in line.
create function public.meet_rsvp_seat()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cap int;
begin
  if new.status = 'maybe' then
    new.waitlisted_at := null;
    return new;
  end if;
  if tg_op = 'UPDATE' and old.status = 'going' and old.meet_id = new.meet_id then
    new.status := 'going';
    new.waitlisted_at := null;
    return new;
  end if;
  select capacity into cap from public.meets where id = new.meet_id for no key update;
  if cap is not null and cap <= (select count(*) from public.meet_rsvps
       where meet_id = new.meet_id and status = 'going' and user_id <> new.user_id) then
    new.status := 'waitlist';
    new.waitlisted_at := case
      when tg_op = 'UPDATE' and old.status = 'waitlist' and old.meet_id = new.meet_id then old.waitlisted_at
      else now() end;
  else
    new.status := 'going';
    new.waitlisted_at := null;
  end if;
  return new;
end;
$$;
revoke all on function public.meet_rsvp_seat() from public, anon, authenticated;
create trigger meet_rsvps_seat before insert or update on public.meet_rsvps
  for each row execute function public.meet_rsvp_seat();

-- A Going RSVP removed or changed frees a seat.
create function public.meet_rsvp_left()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status = 'going'
     and (tg_op = 'DELETE' or new.status <> 'going' or new.meet_id <> old.meet_id) then
    perform public.promote_waitlist(old.meet_id);
  end if;
  return null;
end;
$$;
revoke all on function public.meet_rsvp_left() from public, anon, authenticated;
create trigger meet_rsvps_left after delete or update on public.meet_rsvps
  for each row execute function public.meet_rsvp_left();

-- The host raised or removed the cap.
create function public.on_meet_capacity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.promote_waitlist(new.id);
  return null;
end;
$$;
revoke all on function public.on_meet_capacity() from public, anon, authenticated;
create trigger meets_capacity after update of capacity on public.meets
  for each row when (new.capacity is distinct from old.capacity)
  execute function public.on_meet_capacity();

-- The host's Activity row says which it was (W7-2 wrote "is going" for everything but maybe).
create or replace function public.on_rsvp_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m record;
begin
  select host_id, title into m from public.meets where id = new.meet_id;
  if found then
    perform public.record_notification(m.host_id, 'rsvp', new.user_id,
      'waypoints://meet/' || new.meet_id,
      public.actor_name(new.user_id) || case new.status::text
        when 'maybe' then ' might come' when 'waitlist' then ' joined the waitlist' else ' is going' end,
      m.title, 'rsvp:' || new.meet_id || ':' || new.user_id);
  end if;
  return new;
end;
$$;
