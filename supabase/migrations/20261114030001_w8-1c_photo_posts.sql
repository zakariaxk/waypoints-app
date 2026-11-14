-- W8-1C (FEED-11): photo posts and meet tags. A post is either a video (video_path) or one to
-- six photos in post_photos, swiped sideways in the feed pager. A post can tag a meet the
-- author can see; the meet's page lists posts tagged with it.

alter table public.posts alter column video_path drop not null;
alter table public.posts add column meet_id uuid references public.meets (id) on delete set null;
create index posts_meet_idx on public.posts (meet_id, created_at desc) where meet_id is not null;

create table public.post_photos (
  post_id uuid not null references public.posts (id) on delete cascade,
  sort    int not null check (sort between 0 and 5),
  path    text not null check (char_length(path) between 1 and 300),
  primary key (post_id, sort)
);
alter table public.post_photos enable row level security;

-- Readable when the post is (posts_read applies inside the subquery).
create policy post_photos_read on public.post_photos
  for select to authenticated
  using (exists (select 1 from public.posts p where p.id = post_id));
create policy post_photos_insert_own on public.post_photos
  for insert to authenticated
  with check (exists (select 1 from public.posts p where p.id = post_id and p.author_id = auth.uid()));
-- Deleting the post removes its photos (cascade).

drop policy posts_insert_own on public.posts;
create policy posts_insert_own on public.posts
  for insert to authenticated
  with check (
    author_id = auth.uid()
    and (car_id is null or public.car_owner(car_id) = auth.uid())
    and (meet_id is null or public.can_read_meet(meet_id))
  );
