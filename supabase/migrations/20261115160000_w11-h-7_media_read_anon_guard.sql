-- W11-H-7: split the storage read policy by role.
--
-- W11-H-5's single waypoints_media_read ORs a `messages`-bucket disjunct containing
-- `exists (select ... from public.messages ...)` plus security-definer helpers
-- (thread_open, is_team_member) that anon cannot execute. Postgres does not
-- guarantee the disjunct short-circuits, so anon reads of public-bucket objects
-- raised 42501 (checks.sql "media is publicly readable"). Splitting the policy by
-- role keeps anon's qual free of any messages/public.messages reference: policies
-- `to authenticated` are not even loaded for the anon role.

drop policy waypoints_media_read on storage.objects;

create policy waypoints_media_read_public on storage.objects
  for select to anon, authenticated
  using (bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'catalog'));

create policy waypoints_media_read_messages on storage.objects
  for select to authenticated
  using (
    bucket_id = 'messages'
    and (
      (storage.foldername(name))[1] = auth.uid()::text
      or exists (
        select 1
          from public.messages m
         where m.attachment_path = name
           and case when m.channel_id is not null
             then public.is_team_member(public.channel_team(m.channel_id))
             else public.thread_open(m.thread_id)
           end
      )
    )
  );
