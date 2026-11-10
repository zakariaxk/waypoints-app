-- W5-5: achievement triggers (plan 9.8). Every key rewards participation, never speed or
-- distance. Keys that need live presence (first_meet, host_3, convoy_*) are awarded by the
-- gateway, which sees presence; showdown_top10 by a weekly job.

create or replace function public.award(p_user uuid, p_key text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.achievements (user_id, key) values (p_user, p_key) on conflict do nothing;
$$;
revoke all on function public.award(uuid, text) from public, anon, authenticated;

create or replace function public.award_thresholds(p_user uuid, p_count bigint, p_keys text[], p_targets int[])
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  for i in 1 .. array_length(p_keys, 1) loop
    if p_count >= p_targets[i] then perform public.award(p_user, p_keys[i]); end if;
  end loop;
end;
$$;
revoke all on function public.award_thresholds(uuid, bigint, text[], int[]) from public, anon, authenticated;

create or replace function public.ach_reports()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.confirmations > 1 then
    perform public.award_thresholds(new.author_id,
      (select count(*) from public.reports where author_id = new.author_id and confirmations > 1),
      array['reports_1', 'reports_10', 'reports_50'], array[1, 10, 50]);
  end if;
  return new;
end; $$;
create trigger ach_reports after update of confirmations on public.reports
  for each row execute function public.ach_reports();

create or replace function public.ach_spots()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award_thresholds(new.spotter_id,
    (select count(distinct catalog_model_id) from public.spots where spotter_id = new.spotter_id),
    array['spots_5', 'spots_25', 'spots_100'], array[5, 25, 100]);
  return new;
end; $$;
create trigger ach_spots after insert on public.spots for each row execute function public.ach_spots();

create or replace function public.ach_roads()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award_thresholds(new.user_id,
    (select count(*) from public.road_ratings where user_id = new.user_id),
    array['roads_1', 'roads_5'], array[1, 5]);
  return new;
end; $$;
create trigger ach_roads after insert on public.road_ratings for each row execute function public.ach_roads();

create or replace function public.ach_build()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_owner uuid := (select owner_id from public.cars where id = new.car_id);
begin
  perform public.award_thresholds(v_owner,
    (select count(*) from public.build_entries where car_id = new.car_id), array['build_10'], array[10]);
  perform public.award_thresholds(v_owner,
    (select count(*) from public.build_entries b join public.cars c on c.id = b.car_id where c.owner_id = v_owner),
    array['build_25'], array[25]);
  return new;
end; $$;
create trigger ach_build after insert on public.build_entries for each row execute function public.ach_build();

create or replace function public.ach_race()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.award(new.user_id, 'strip_1');
  if new.et_ms < 12000 then perform public.award(new.user_id, 'strip_12s'); end if;
  if new.et_ms < 10000 then perform public.award(new.user_id, 'strip_10s'); end if;
  return new;
end; $$;
create trigger ach_race after insert on public.race_results for each row execute function public.ach_race();

create or replace function public.ach_simple()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_count bigint;
begin
  case tg_table_name
    when 'posts' then
      v_user := new.author_id;
      perform public.award_thresholds(v_user, (select count(*) from public.posts where author_id = v_user), array['posts_5'], array[5]);
    when 'listings' then
      perform public.award(new.seller_id, 'listing_1');
    when 'venue_notes' then
      v_user := new.author_id;
      perform public.award_thresholds(v_user, (select count(*) from public.venue_notes where author_id = v_user), array['venue_5'], array[5]);
    when 'team_members' then
      perform public.award(new.user_id, 'teams_join');
    when 'showdown_votes' then
      v_user := new.voter_id;
      perform public.award_thresholds(v_user, (select count(*) from public.showdown_votes where voter_id = v_user), array['showdown_50'], array[50]);
    when 'meet_rsvps' then
      if new.status = 'going' then
        v_user := new.user_id;
        perform public.award_thresholds(v_user,
          (select count(*) from public.meet_rsvps where user_id = v_user and status = 'going'), array['meets_1', 'meets_5'], array[1, 5]);
      end if;
    when 'friendships' then
      if new.status = 'accepted' then
        foreach v_user in array array[new.requester_id, new.addressee_id] loop
          select count(*) into v_count from public.friendships
           where status = 'accepted' and (requester_id = v_user or addressee_id = v_user);
          perform public.award_thresholds(v_user, v_count, array['friends_5'], array[5]);
        end loop;
      end if;
  end case;
  return new;
end; $$;

create trigger ach_posts after insert on public.posts for each row execute function public.ach_simple();
create trigger ach_listings after insert on public.listings for each row execute function public.ach_simple();
create trigger ach_venue after insert on public.venue_notes for each row execute function public.ach_simple();
create trigger ach_teams after insert on public.team_members for each row execute function public.ach_simple();
create trigger ach_votes after insert on public.showdown_votes for each row execute function public.ach_simple();
create trigger ach_rsvps after insert or update of status on public.meet_rsvps for each row execute function public.ach_simple();
create trigger ach_friends after update of status on public.friendships for each row execute function public.ach_simple();
