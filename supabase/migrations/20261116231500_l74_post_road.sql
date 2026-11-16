-- L74 (FEED-12): a post can tag a rated road. The road sheet's "Post it" opens the composer
-- with the road attached; the feed renders a road chip that opens the road. Roads are
-- readable by every signed-in user, so posts_insert_own needs no extra check (unlike
-- meet_id, which gates on can_read_meet). The feed RPCs return `setof posts` and select
-- po.*, so the new column flows through without touching them.

alter table public.posts add column road_id uuid references public.roads (id) on delete set null;
create index posts_road_idx on public.posts (road_id, created_at desc) where road_id is not null;
