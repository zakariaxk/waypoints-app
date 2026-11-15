-- W9-H: hardening pass over access rules (SEC-1, SEC-4, SAFE-6, SAFE-7).
--
-- 1. suspended_write_guard on the RLS tables created after W6-B ran (meet_votes, post_photos).
-- 2. is_blocked_pair and are_friends answered for any two ids, so a signed-in caller could ask
--    over RPC whether two other people are friends or have blocked each other. They now
--    answer only when the caller is one of the pair (or there is no caller: gateway, triggers).
-- 3. No security definer function is callable by anon (can_read_help and can_pick_car were).
-- 4. Showdown withdraw: owners may delete their own entry (the client's withdraw was refused).
-- 5. People's choice: PostgREST's upsert sets every column it was sent, so meet_votes needs
--    update on its key columns too; the policy still pins voter_id and the car.
-- 6. Read rules that ignored moderation: listing photos follow their listing, comments follow
--    their post, Strip runs of suspended accounts drop out.
-- 7. Team roles: manage_roles cannot create, edit, or assign a role with permissions the
--    caller does not hold.
-- 8. Storage: the messages bucket stays public by URL (plan section 5), but only the uploader
--    can list or query its objects; before, anyone with the anon key could enumerate every
--    attachment path.
-- 9. Index for "my saved listings".

set search_path = public, extensions;

-- 1. Write guard ---------------------------------------------------------------

do $$
declare t text;
begin
  for t in
    select c.relname
    from pg_class c
    where c.relnamespace = 'public'::regnamespace
      and c.relkind = 'r'
      and c.relrowsecurity
      and not exists (
        select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'suspended_write_guard')
  loop
    execute format(
      'create trigger suspended_write_guard before insert or update on public.%I
         for each row execute function public.suspended_write_guard()', t);
  end loop;
end $$;

-- 2. Pair helpers --------------------------------------------------------------

create or replace function public.is_blocked_pair(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select (auth.uid() is null or auth.uid() in (a, b))
     and exists (
       select 1 from public.blocks
       where (blocker_id = a and blocked_id = b)
          or (blocker_id = b and blocked_id = a)
     );
$$;

create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select (auth.uid() is null or auth.uid() in (a, b))
     and exists (
       select 1 from public.friendships
       where status = 'accepted'
         and least(requester_id, addressee_id) = least(a, b)
         and greatest(requester_id, addressee_id) = greatest(a, b)
     );
$$;

-- 3. Security definer functions: never anon --------------------------------------
-- Roles that could execute a function keep it; only public and anon lose it.

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig,
           has_function_privilege('authenticated', p.oid, 'execute') as authed,
           has_function_privilege('service_role', p.oid, 'execute') as service
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prosecdef
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    if f.authed then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    if f.service then
      execute format('grant execute on function %s to service_role', f.sig);
    end if;
  end loop;
end $$;

-- 4. Showdown withdraw ---------------------------------------------------------

grant delete on public.showdown_entries to authenticated;
create policy showdown_entries_withdraw_own on public.showdown_entries
  for delete to authenticated
  using (public.car_owner(car_id) = auth.uid());

-- 5. People's choice upsert ----------------------------------------------------

grant update (meet_id, voter_id) on public.meet_votes to authenticated;

-- 6. Read rules ----------------------------------------------------------------

-- Readable when the listing is (listings_read applies inside the subquery).
drop policy listing_photos_read on public.listing_photos;
create policy listing_photos_read on public.listing_photos
  for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id));

drop policy post_comments_read on public.post_comments;
create policy post_comments_read on public.post_comments
  for select to authenticated
  using (public.content_visible(author_id, hidden_at) and public.post_visible(post_id));

drop policy race_results_read on public.race_results;
create policy race_results_read on public.race_results
  for select to authenticated
  using (public.content_visible(user_id, null));

-- 7. Team roles ----------------------------------------------------------------

drop policy team_roles_write on public.team_roles;
create policy team_roles_write on public.team_roles
  for all to authenticated
  using (public.has_team_permission(team_id, 4))
  with check (
    public.has_team_permission(team_id, 4)
    and (permissions & ~public.team_permissions(team_id)) = 0
  );

drop policy team_members_set_role on public.team_members;
create policy team_members_set_role on public.team_members
  for update to authenticated
  using (public.has_team_permission(team_id, 4))
  with check (
    public.has_team_permission(team_id, 4)
    and (public.role_permissions(role_id) & ~public.team_permissions(team_id)) = 0
  );

-- 8. Storage -------------------------------------------------------------------

drop policy waypoints_media_read on storage.objects;
create policy waypoints_media_read on storage.objects
  for select to anon, authenticated
  using (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'catalog')
    or (bucket_id = 'messages' and (storage.foldername(name))[1] = auth.uid()::text)
  );

-- 9. Index ---------------------------------------------------------------------

create index if not exists listing_saves_user_idx on public.listing_saves (user_id);
