-- L100 (FEED-13): the owner can edit their own post's caption.
--
-- W0-C revoked update on posts outright; restoring it is column-scoped so
-- author_id, counts, and media paths stay server-owned. Only caption is
-- writable, same shape as the profiles/friendships column grants.

grant update (caption) on public.posts to authenticated;

create policy posts_update_own on public.posts
  for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());
