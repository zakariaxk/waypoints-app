-- W11-H-5: DM attachments are private end to end ----------------------------------
--
-- `messages` was the only user-content bucket still public by URL: anyone holding
-- /storage/v1/object/public/messages/<uid>/<uuid>.<ext> could fetch a DM photo, and
-- storage.objects policies cannot gate that path. The fix is the bucket flag plus an
-- authenticated, participant-scoped read: downloads now go through signed URLs (or an
-- authenticated storage request) and only the uploader's folder, thread parties, and
-- channel members may read an object.
--
-- Every other bucket stays public on purpose: avatars, cars, listings, spots, teams
-- and posts are shown to people who are not friends (map, feed, market), and `catalog`
-- is fetched by CatalogUpdater without a session. Making any of them private would
-- break those surfaces for a confidentiality gain they do not need.

update storage.buckets set public = false where id = 'messages';

-- The W9-H read policy limited `messages` objects to the uploader's own folder, which
-- was enough while the bucket was public-by-URL (recipients never went through this
-- policy). With the bucket private, recipients must pass it too: an object is
-- readable when a `messages` row points at it and the caller could read that message
-- (channel member or open thread party), or when it sits in the caller's own folder
-- (covers the upload-before-message-insert window and keeps account deletion's
-- list/remove working). Insert/update/delete policies are unchanged: writes already
-- require ownership of the first path folder.

drop policy waypoints_media_read on storage.objects;
create policy waypoints_media_read on storage.objects
  for select to anon, authenticated
  using (
    bucket_id in ('avatars', 'cars', 'posts', 'listings', 'spots', 'teams', 'catalog')
    or (bucket_id = 'messages'
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
        ))
  );
