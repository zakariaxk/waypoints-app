-- L75 (ICN-8): achievement keys for the surfaces added since plan 9.8 — the first
-- saved loop, the first guide logged to a car timeline, and a spot milestone past
-- the first. Same rules as W5-5: trigger-awarded participation, never speed or
-- distance.
--
-- `ach_spots` and `ach_build` are replaced in place (their triggers call the
-- functions by name); `road_loops` gets its own trigger.

create or replace function public.ach_loops()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award(new.owner_id, 'loop_saved');
  return new;
end; $$;
create trigger ach_loops after insert on public.road_loops for each row execute function public.ach_loops();

create or replace function public.ach_spots()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award_thresholds(new.spotter_id,
    (select count(distinct catalog_model_id) from public.spots where spotter_id = new.spotter_id),
    array['spots_5', 'spots_10', 'spots_25', 'spots_100'], array[5, 10, 25, 100]);
  return new;
end; $$;

-- A guide logged to a timeline is a build entry whose body carries the KNW-7
-- prefix ("Waypoints guide · <vehicle>"). `mod_id` cannot mark it: guides with no
-- linked mods write NULL, and mod installs write the id without the prefix.
create or replace function public.ach_build()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid := (select owner_id from public.cars where id = new.car_id);
begin
  perform public.award_thresholds(v_owner,
    (select count(*) from public.build_entries where car_id = new.car_id), array['build_10'], array[10]);
  perform public.award_thresholds(v_owner,
    (select count(*) from public.build_entries b join public.cars c on c.id = b.car_id where c.owner_id = v_owner),
    array['build_25'], array[25]);
  if new.body like 'Waypoints guide · %' then perform public.award(v_owner, 'guide_logged'); end if;
  return new;
end; $$;
