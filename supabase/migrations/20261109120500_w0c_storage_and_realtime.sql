-- W0-C: storage buckets and policies, Realtime publication (plan 5.4, 5.5).
-- Media buckets: public read, owner write under "<user_id>/...".
-- catalog: public read, service-role write (no write policy).

insert into storage.buckets (id, name, public)
values
  ('avatars',  'avatars',  true),
  ('cars',     'cars',     true),
  ('posts',    'posts',    true),
  ('listings', 'listings', true),
  ('spots',    'spots',    true),
  ('teams',    'teams',    true),
  ('messages', 'messages', true),
  ('catalog',  'catalog',  true)
on conflict (id) do update set public = excluded.public;

create policy waypoints_media_read on storage.objects
  for select to anon, authenticated
  using (bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages', 'catalog'));

create policy waypoints_media_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy waypoints_media_update_own on storage.objects
  for update to authenticated
  using (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages')
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy waypoints_media_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'messages')
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Chat delivery: Postgres Changes on messages. Realtime applies the
-- messages_read policy per subscriber.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

alter publication supabase_realtime add table public.messages;
