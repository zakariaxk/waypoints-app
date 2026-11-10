-- W0-C: access helpers used by RLS policies, and triggers.
-- Helpers are security definer so policies can consult other tables without
-- recursing through those tables' own policies. They only ever answer
-- questions about auth.uid(), so they leak nothing a caller could not learn.

set search_path = public, extensions;

-- Access helpers ----------------------------------------------------------

create function public.is_blocked_pair(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- Signed in and not blocked by the owner.
create function public.can_read_profile(owner uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select auth.uid() is not null
     and not exists (
       select 1 from public.blocks
       where blocker_id = owner and blocked_id = auth.uid()
     );
$$;

create function public.are_friends(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.friendships
    where status = 'accepted'
      and least(requester_id, addressee_id) = least(a, b)
      and greatest(requester_id, addressee_id) = greatest(a, b)
  );
$$;

create function public.car_owner(car uuid)
returns uuid
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select owner_id from public.cars where id = car;
$$;

create function public.can_read_car(car uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.cars c
    where c.id = car and public.can_read_profile(c.owner_id)
  );
$$;

create function public.car_has_photo(car uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (select 1 from public.car_photos where car_id = car);
$$;

create function public.is_team_member(team uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.team_members
    where team_id = team and user_id = auth.uid()
  );
$$;

create function public.team_is_public(team uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select is_public from public.teams where id = team), false);
$$;

create function public.team_owner(team uuid)
returns uuid
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select owner_id from public.teams where id = team;
$$;

-- The caller's permission bitset in a team. The owner holds every bit.
create function public.team_permissions(team uuid)
returns int
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select case
    when auth.uid() is null then 0
    when exists (select 1 from public.teams where id = team and owner_id = auth.uid()) then 63
    else coalesce((
      select r.permissions
      from public.team_members m
      join public.team_roles r on r.id = m.role_id
      where m.team_id = team and m.user_id = auth.uid()
    ), 0)
  end;
$$;

create function public.has_team_permission(team uuid, perm int)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select (public.team_permissions(team) & perm) <> 0;
$$;

create function public.role_permissions(role uuid)
returns int
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select coalesce((select permissions from public.team_roles where id = role), 0);
$$;

create function public.channel_team(channel uuid)
returns uuid
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select team_id from public.channels where id = channel;
$$;

create function public.meet_visible(host uuid, vis public.meet_visibility, team uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select auth.uid() is not null and (
    host = auth.uid()
    or (
      not public.is_blocked_pair(host, auth.uid())
      and case vis
        when 'public' then true
        when 'friends' then public.are_friends(host, auth.uid())
        when 'team' then public.is_team_member(team)
      end
    )
  );
$$;

create function public.can_read_meet(meet uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.meets m
    where m.id = meet and public.meet_visible(m.host_id, m.visibility, m.team_id)
  );
$$;

-- Caller is a party to the thread and neither party has blocked the other.
create function public.thread_open(thread uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.threads t
    where t.id = thread
      and auth.uid() in (t.a_id, t.b_id)
      and not public.is_blocked_pair(t.a_id, t.b_id)
  );
$$;

create function public.listing_seller(listing uuid)
returns uuid
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select seller_id from public.listings where id = listing;
$$;

create function public.post_author(post uuid)
returns uuid
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select author_id from public.posts where id = post;
$$;

create function public.post_visible(post uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.posts p
    where p.id = post
      and auth.uid() is not null
      and not public.is_blocked_pair(p.author_id, auth.uid())
  );
$$;

-- Report lifetimes (plan 5.3). Null means permanent.
create function public.report_lifetime(k public.report_kind)
returns interval
language sql immutable
set search_path = public, extensions, pg_temp
as $$
  select case k
    when 'police'     then interval '45 minutes'
    when 'hazard'     then interval '2 hours'
    when 'closure'    then interval '24 hours'
    when 'pothole'    then interval '90 days'
    when 'rough_road' then interval '90 days'
    else null
  end;
$$;

-- True when the current statement runs as an end-user role (not postgres,
-- service_role, or a security definer function).
create function public.is_end_user()
returns boolean
language sql stable
set search_path = public, extensions, pg_temp
as $$
  select current_user in ('authenticated', 'anon');
$$;

-- Triggers --------------------------------------------------------------

-- Profile and privacy rows on sign-up. The handle comes from user metadata
-- when it is valid and free, otherwise a generated one the user can change.
create function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_handle text := lower(coalesce(new.raw_user_meta_data ->> 'handle', ''));
  v_name   text := left(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 30);
  v_year   int;
begin
  if v_handle !~ '^[a-z0-9_]{3,20}$'
     or exists (select 1 from public.profiles where handle = v_handle) then
    v_handle := 'driver_' || substr(replace(new.id::text, '-', ''), 1, 12);
  end if;
  if v_name = '' then
    v_name := v_handle;
  end if;
  begin
    v_year := (new.raw_user_meta_data ->> 'birth_year')::int;
  exception when others then
    v_year := null;
  end;

  insert into public.profiles (user_id, handle, display_name, birth_year)
  values (new.id, v_handle, v_name, v_year);
  insert into public.privacy_settings (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Minimum age 17 (plan 2.5), at year precision.
create function public.profiles_check_age()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if new.birth_year is not null
     and new.birth_year > extract(year from now())::int - 17 then
    raise exception 'Waypoints is for drivers 17 and older'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger profiles_check_age
  before insert or update of birth_year on public.profiles
  for each row execute function public.profiles_check_age();

-- Blocking someone ends the friendship and follows in both directions.
create function public.blocks_cleanup()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  delete from public.friendships
  where least(requester_id, addressee_id) = least(new.blocker_id, new.blocked_id)
    and greatest(requester_id, addressee_id) = greatest(new.blocker_id, new.blocked_id);
  delete from public.follows
  where (follower_id = new.blocker_id and followee_id = new.blocked_id)
     or (follower_id = new.blocked_id and followee_id = new.blocker_id);
  return new;
end;
$$;

create trigger blocks_cleanup
  after insert on public.blocks
  for each row execute function public.blocks_cleanup();

-- Fill report lifetime from its kind when the writer did not.
create function public.reports_defaults()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if public.report_lifetime(new.kind) is null then
    new.permanent := true;
    new.expires_at := null;
  elsif new.expires_at is null then
    new.permanent := false;
    new.expires_at := now() + public.report_lifetime(new.kind);
  end if;
  return new;
end;
$$;

create trigger reports_defaults
  before insert on public.reports
  for each row execute function public.reports_defaults();

create function public.roads_length()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  new.length_m := round(st_length(new.path))::int;
  return new;
end;
$$;

create trigger roads_length
  before insert or update of path on public.roads
  for each row execute function public.roads_length();

-- Every team starts with roles Owner (all permissions) and Member (none),
-- the owner as a member, and channels general (text) and Garage (voice).
create function public.teams_bootstrap()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_owner_role uuid;
begin
  insert into public.team_roles (team_id, name, rank, permissions)
  values (new.id, 'Owner', 100, 63)
  returning id into v_owner_role;
  insert into public.team_roles (team_id, name, rank, permissions)
  values (new.id, 'Member', 0, 0);

  insert into public.team_members (team_id, user_id, role_id)
  values (new.id, new.owner_id, v_owner_role);

  insert into public.channels (team_id, name, kind, sort)
  values (new.id, 'general', 'text', 0),
         (new.id, 'Garage', 'voice', 1);
  return new;
end;
$$;

create trigger teams_bootstrap
  after insert on public.teams
  for each row execute function public.teams_bootstrap();

-- New members without a role get the team's lowest-ranked role with no
-- permissions (the default "Member").
create function public.team_members_default_role()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.role_id is null then
    select id into new.role_id
    from public.team_roles
    where team_id = new.team_id and permissions = 0
    order by rank, created_at
    limit 1;
  end if;
  return new;
end;
$$;

create trigger team_members_default_role
  before insert on public.team_members
  for each row execute function public.team_members_default_role();

-- Soft delete clears content.
create function public.messages_soft_delete()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    new.body := '';
    new.attachment_path := null;
  end if;
  return new;
end;
$$;

create trigger messages_soft_delete
  before update on public.messages
  for each row execute function public.messages_soft_delete();

-- End users cannot seed counters or ratings.
create function public.posts_reset_counts()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if public.is_end_user() then
    new.like_count := 0;
    new.comment_count := 0;
  end if;
  return new;
end;
$$;

create trigger posts_reset_counts
  before insert on public.posts
  for each row execute function public.posts_reset_counts();

create function public.showdown_entries_reset()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
begin
  if public.is_end_user() then
    new.rating := 1200;
    new.wins := 0;
    new.losses := 0;
  end if;
  return new;
end;
$$;

create trigger showdown_entries_reset
  before insert on public.showdown_entries
  for each row execute function public.showdown_entries_reset();

create function public.post_likes_count()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set like_count = like_count + 1 where id = new.post_id;
  else
    update public.posts set like_count = greatest(like_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end;
$$;

create trigger post_likes_count
  after insert or delete on public.post_likes
  for each row execute function public.post_likes_count();

create function public.post_comments_count()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.posts set comment_count = comment_count + 1 where id = new.post_id;
  else
    update public.posts set comment_count = greatest(comment_count - 1, 0) where id = old.post_id;
  end if;
  return null;
end;
$$;

create trigger post_comments_count
  after insert or delete on public.post_comments
  for each row execute function public.post_comments_count();
