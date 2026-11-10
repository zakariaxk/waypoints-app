-- W0-C: row-level security (plan section 5, "Access rule" columns).
-- No policy means no access for anon and authenticated; service_role and the
-- table owner bypass RLS. "Through gateway" and "service role" tables
-- therefore get read policies at most.

set search_path = public, extensions;

-- RLS on everywhere ----------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'friendships', 'blocks', 'privacy_settings', 'user_presence_cell',
    'device_tokens', 'cars', 'car_photos', 'build_entries', 'reports',
    'report_votes', 'meets', 'meet_rsvps', 'venue_notes', 'roads', 'road_ratings',
    'spots', 'teams', 'team_roles', 'team_members', 'channels', 'threads',
    'messages', 'read_markers', 'posts', 'post_likes', 'post_comments', 'follows',
    'showdown_entries', 'showdown_votes', 'listings', 'listing_photos',
    'listing_saves', 'achievements', 'content_reports', 'race_results'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Grants: anon reads achievements only. Column grants pin what an update
-- may touch where RLS alone cannot.

revoke all on all tables in schema public from anon;
grant select on public.achievements to anon;

revoke all on public.user_presence_cell, public.report_votes from authenticated;
revoke insert, update, delete on public.privacy_settings, public.reports, public.meets,
  public.showdown_votes, public.achievements from authenticated;
revoke update, delete on public.showdown_entries from authenticated;
revoke select, update on public.content_reports from authenticated;

revoke update on public.profiles from authenticated;
grant update (handle, display_name, bio, avatar_path, home_region, marker_icon,
  marker_trail, primary_car_id, birth_year, accepted_terms_at)
  on public.profiles to authenticated;

revoke update on public.friendships from authenticated;
grant update (status) on public.friendships to authenticated;

revoke update on public.teams from authenticated;
grant update (name, tag, about, icon_path, is_public, invite_code) on public.teams to authenticated;

revoke update on public.team_members from authenticated;
grant update (role_id) on public.team_members to authenticated;

revoke update on public.messages from authenticated;
grant update (deleted_at) on public.messages to authenticated;

revoke update on public.posts, public.post_likes, public.post_comments,
  public.device_tokens, public.race_results, public.venue_notes, public.roads,
  public.spots, public.threads from authenticated;

-- 5.1 People ------------------------------------------------------------

create policy profiles_read on public.profiles
  for select to authenticated
  using (public.can_read_profile(user_id));
create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (user_id = auth.uid());
create policy profiles_update_self on public.profiles
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and (primary_car_id is null or public.car_owner(primary_car_id) = auth.uid())
  );
create policy profiles_delete_self on public.profiles
  for delete to authenticated
  using (user_id = auth.uid());

create policy friendships_read on public.friendships
  for select to authenticated
  using (auth.uid() in (requester_id, addressee_id));
create policy friendships_request on public.friendships
  for insert to authenticated
  with check (
    requester_id = auth.uid()
    and status = 'pending'
    and not public.is_blocked_pair(requester_id, addressee_id)
  );
create policy friendships_accept on public.friendships
  for update to authenticated
  using (addressee_id = auth.uid())
  with check (addressee_id = auth.uid() and status = 'accepted');
create policy friendships_delete on public.friendships
  for delete to authenticated
  using (auth.uid() in (requester_id, addressee_id));

create policy blocks_owner on public.blocks
  for all to authenticated
  using (blocker_id = auth.uid())
  with check (blocker_id = auth.uid());

create policy privacy_settings_read_own on public.privacy_settings
  for select to authenticated
  using (user_id = auth.uid());

-- user_presence_cell: service role only (no policies).

-- Owner read is required: Postgres applies SELECT policies to DELETE ... WHERE.
create policy device_tokens_read_own on public.device_tokens
  for select to authenticated
  using (user_id = auth.uid());
create policy device_tokens_insert_own on public.device_tokens
  for insert to authenticated
  with check (user_id = auth.uid());
create policy device_tokens_delete_own on public.device_tokens
  for delete to authenticated
  using (user_id = auth.uid());

-- 5.2 Garage ------------------------------------------------------------

create policy cars_read on public.cars
  for select to authenticated
  using (public.can_read_profile(owner_id));
create policy cars_insert_own on public.cars
  for insert to authenticated
  with check (owner_id = auth.uid());
create policy cars_update_own on public.cars
  for update to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());
create policy cars_delete_own on public.cars
  for delete to authenticated
  using (owner_id = auth.uid());

create policy car_photos_read on public.car_photos
  for select to authenticated
  using (public.can_read_car(car_id));
create policy car_photos_write_own on public.car_photos
  for all to authenticated
  using (public.car_owner(car_id) = auth.uid())
  with check (public.car_owner(car_id) = auth.uid());

create policy build_entries_read on public.build_entries
  for select to authenticated
  using (public.can_read_car(car_id));
create policy build_entries_write_own on public.build_entries
  for all to authenticated
  using (public.car_owner(car_id) = auth.uid())
  with check (public.car_owner(car_id) = auth.uid());

-- 5.3 Map content -------------------------------------------------------

create policy reports_read on public.reports
  for select to authenticated
  using (true);
-- reports insert/confirm/dismiss and report_votes: gateway only.

create policy meets_read on public.meets
  for select to authenticated
  using (public.meet_visible(host_id, visibility, team_id));
-- meets insert/update: gateway only.

create policy meet_rsvps_read on public.meet_rsvps
  for select to authenticated
  using (public.can_read_meet(meet_id));
create policy meet_rsvps_insert_own on public.meet_rsvps
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.can_read_meet(meet_id)
    and (car_id is null or public.car_owner(car_id) = auth.uid())
  );
create policy meet_rsvps_update_own on public.meet_rsvps
  for update to authenticated
  using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and public.can_read_meet(meet_id)
    and (car_id is null or public.car_owner(car_id) = auth.uid())
  );
create policy meet_rsvps_delete_own on public.meet_rsvps
  for delete to authenticated
  using (user_id = auth.uid());

create policy venue_notes_read on public.venue_notes
  for select to authenticated
  using (true);
create policy venue_notes_insert on public.venue_notes
  for insert to authenticated
  with check (author_id = auth.uid());

create policy roads_read on public.roads
  for select to authenticated
  using (true);
create policy roads_insert_own on public.roads
  for insert to authenticated
  with check (author_id = auth.uid());

create policy road_ratings_read on public.road_ratings
  for select to authenticated
  using (true);
create policy road_ratings_insert_own on public.road_ratings
  for insert to authenticated
  with check (user_id = auth.uid());
create policy road_ratings_update_own on public.road_ratings
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
create policy road_ratings_delete_own on public.road_ratings
  for delete to authenticated
  using (user_id = auth.uid());

create policy spots_read on public.spots
  for select to authenticated
  using (true);
create policy spots_insert_own on public.spots
  for insert to authenticated
  with check (spotter_id = auth.uid());

-- 5.4 Teams and messaging -------------------------------------------------

create policy teams_read on public.teams
  for select to authenticated
  using (is_public or owner_id = auth.uid() or public.is_team_member(id));
create policy teams_insert_own on public.teams
  for insert to authenticated
  with check (owner_id = auth.uid());
create policy teams_update_managers on public.teams
  for update to authenticated
  using (public.has_team_permission(id, 1))
  with check (public.has_team_permission(id, 1));
create policy teams_delete_owner on public.teams
  for delete to authenticated
  using (owner_id = auth.uid());

create policy team_roles_read on public.team_roles
  for select to authenticated
  using (public.is_team_member(team_id));
create policy team_roles_write on public.team_roles
  for all to authenticated
  using (public.has_team_permission(team_id, 4))
  with check (public.has_team_permission(team_id, 4));

create policy team_members_read on public.team_members
  for select to authenticated
  using (public.is_team_member(team_id));
-- Self-join of a public team, as a role with no permissions. Private teams
-- are joined through join_team(code).
create policy team_members_join_public on public.team_members
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and public.team_is_public(team_id)
    and public.role_permissions(role_id) = 0
  );
create policy team_members_set_role on public.team_members
  for update to authenticated
  using (public.has_team_permission(team_id, 4))
  with check (public.has_team_permission(team_id, 4));
-- Leave, or kick. The owner cannot be removed (delete the team instead).
create policy team_members_leave_or_kick on public.team_members
  for delete to authenticated
  using (
    user_id <> public.team_owner(team_id)
    and (user_id = auth.uid() or public.has_team_permission(team_id, 8))
  );

create policy channels_read on public.channels
  for select to authenticated
  using (public.is_team_member(team_id));
create policy channels_write on public.channels
  for all to authenticated
  using (public.has_team_permission(team_id, 2))
  with check (public.has_team_permission(team_id, 2));

create policy threads_read on public.threads
  for select to authenticated
  using (auth.uid() in (a_id, b_id) and not public.is_blocked_pair(a_id, b_id));
create policy threads_insert on public.threads
  for insert to authenticated
  with check (
    auth.uid() in (a_id, b_id)
    and not public.is_blocked_pair(a_id, b_id)
    and (kind = 'dm' or public.listing_seller(listing_id) in (a_id, b_id))
  );

create policy messages_read on public.messages
  for select to authenticated
  using (
    case when channel_id is not null
      then public.is_team_member(public.channel_team(channel_id))
      else public.thread_open(thread_id)
    end
  );
create policy messages_insert on public.messages
  for insert to authenticated
  with check (
    author_id = auth.uid()
    and deleted_at is null
    and case when channel_id is not null
      then public.is_team_member(public.channel_team(channel_id))
      else public.thread_open(thread_id)
    end
  );
-- Soft delete only (column grant limits updates to deleted_at).
create policy messages_soft_delete on public.messages
  for update to authenticated
  using (
    author_id = auth.uid()
    or (channel_id is not null and public.has_team_permission(public.channel_team(channel_id), 16))
  )
  with check (deleted_at is not null);

create policy read_markers_owner on public.read_markers
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- 5.5 Feed, Showdown, Market, Progress, Safety --------------------------------

create policy posts_read on public.posts
  for select to authenticated
  using (not public.is_blocked_pair(author_id, auth.uid()));
create policy posts_insert_own on public.posts
  for insert to authenticated
  with check (
    author_id = auth.uid()
    and (car_id is null or public.car_owner(car_id) = auth.uid())
  );
create policy posts_delete_own on public.posts
  for delete to authenticated
  using (author_id = auth.uid());

create policy post_likes_read_own on public.post_likes
  for select to authenticated
  using (user_id = auth.uid());
create policy post_likes_insert_own on public.post_likes
  for insert to authenticated
  with check (user_id = auth.uid() and public.post_visible(post_id));
create policy post_likes_delete_own on public.post_likes
  for delete to authenticated
  using (user_id = auth.uid());

create policy post_comments_read on public.post_comments
  for select to authenticated
  using (true);
create policy post_comments_insert on public.post_comments
  for insert to authenticated
  with check (author_id = auth.uid() and public.post_visible(post_id));
create policy post_comments_delete on public.post_comments
  for delete to authenticated
  using (author_id = auth.uid() or public.post_author(post_id) = auth.uid());

create policy follows_owner on public.follows
  for all to authenticated
  using (follower_id = auth.uid())
  with check (follower_id = auth.uid() and not public.is_blocked_pair(follower_id, followee_id));

create policy showdown_entries_read on public.showdown_entries
  for select to authenticated
  using (true);
create policy showdown_entries_enter_own on public.showdown_entries
  for insert to authenticated
  with check (public.car_owner(car_id) = auth.uid() and public.car_has_photo(car_id));

create policy showdown_votes_read_own on public.showdown_votes
  for select to authenticated
  using (voter_id = auth.uid());
-- showdown_votes insert: only through cast_showdown_vote().

create policy listings_read on public.listings
  for select to authenticated
  using (true);
create policy listings_insert_own on public.listings
  for insert to authenticated
  with check (
    seller_id = auth.uid()
    and (car_id is null or public.car_owner(car_id) = auth.uid())
  );
create policy listings_update_own on public.listings
  for update to authenticated
  using (seller_id = auth.uid())
  with check (
    seller_id = auth.uid()
    and (car_id is null or public.car_owner(car_id) = auth.uid())
  );
create policy listings_delete_own on public.listings
  for delete to authenticated
  using (seller_id = auth.uid());

create policy listing_photos_read on public.listing_photos
  for select to authenticated
  using (true);
create policy listing_photos_write_own on public.listing_photos
  for all to authenticated
  using (public.listing_seller(listing_id) = auth.uid())
  with check (public.listing_seller(listing_id) = auth.uid());

create policy listing_saves_owner on public.listing_saves
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy achievements_read on public.achievements
  for select to anon, authenticated
  using (true);
-- achievements insert: service role or security definer triggers.

create policy content_reports_insert_self on public.content_reports
  for insert to authenticated
  with check (reporter_id = auth.uid());

create policy race_results_read on public.race_results
  for select to authenticated
  using (true);
create policy race_results_insert_own on public.race_results
  for insert to authenticated
  with check (user_id = auth.uid() and public.car_owner(car_id) = auth.uid());
revoke delete on public.race_results from authenticated;

-- Helpers are for policies and signed-in callers only.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'is_blocked_pair', 'can_read_profile', 'are_friends', 'car_owner',
        'can_read_car', 'car_has_photo', 'is_team_member', 'team_is_public',
        'team_owner', 'team_permissions', 'has_team_permission', 'role_permissions',
        'channel_team', 'meet_visible', 'can_read_meet', 'thread_open',
        'listing_seller', 'post_author', 'post_visible'
      )
  loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end $$;
