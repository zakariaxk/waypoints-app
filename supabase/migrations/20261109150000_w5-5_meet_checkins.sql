-- W5-5: check-ins written by the gateway when a Going RSVP is within 200 m of a meet during
-- it (plan 10.4 E2 live state). Feeds first_meet and host_3 (plan 9.8). No coordinates stored.

create table public.meet_checkins (
  meet_id    uuid not null references public.meets (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (meet_id, user_id)
);

alter table public.meet_checkins enable row level security;
create policy meet_checkins_read on public.meet_checkins for select to authenticated
  using (public.can_read_meet(meet_id));
grant select on public.meet_checkins to authenticated;

create or replace function public.ach_checkins()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_host uuid := (select host_id from public.meets where id = new.meet_id);
begin
  perform public.award(new.user_id, 'first_meet');
  perform public.award_thresholds(v_host,
    (select count(*) from (select c.meet_id from public.meet_checkins c join public.meets m on m.id = c.meet_id
                           where m.host_id = v_host group by c.meet_id having count(*) >= 5) t),
    array['host_3'], array[3]);
  return new;
end; $$;
create trigger ach_checkins after insert on public.meet_checkins for each row execute function public.ach_checkins();
