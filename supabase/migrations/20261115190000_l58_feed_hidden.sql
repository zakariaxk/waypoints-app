-- L58 (FEED-5): "Not interested" persists. A hidden post never returns for that user in
-- either feed; the row is owner-only.

create table public.feed_hidden (
  user_id    uuid not null references profiles (user_id) on delete cascade,
  post_id    uuid not null references posts (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id)
);

alter table public.feed_hidden enable row level security;

create policy feed_hidden_own on public.feed_hidden
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

revoke all on public.feed_hidden from public, anon;
grant select, insert, delete on public.feed_hidden to authenticated;

create trigger suspended_write_guard before insert or update on public.feed_hidden
  for each row execute function public.suspended_write_guard();

-- Same function as 20261114030000_w8-1c_feed_for_you_region_only.sql, minus hidden posts.
create or replace function public.feed_for_you(after int default 0, lim int default 10)
returns setof public.posts
language sql stable security definer
set search_path = public, pg_temp
as $$
  with viewer as (
    select nullif(lower(btrim(p.home_region)), '') as region
    from public.profiles p
    where p.user_id = auth.uid()
  )
  select po.*
  from public.posts po
  join public.profiles a on a.user_id = po.author_id
  left join viewer v on true
  where auth.uid() is not null
    and not public.is_blocked_pair(po.author_id, auth.uid())
    and public.content_visible(po.author_id, po.hidden_at)
    and not exists (select 1 from public.feed_hidden h
                    where h.user_id = auth.uid() and h.post_id = po.id)
  order by
    coalesce(v.region is not null and nullif(lower(btrim(a.home_region)), '') = v.region, false) desc,
    ln(1 + po.like_count) - extract(epoch from (now() - po.created_at)) / 86400.0 desc,
    po.created_at desc,
    po.id
  offset greatest(coalesce(feed_for_you.after, 0), 0)
  limit least(greatest(coalesce(feed_for_you.lim, 10), 1), 50);
$$;

revoke all on function public.feed_for_you(int, int) from public, anon;
grant execute on function public.feed_for_you(int, int) to authenticated, service_role;

-- Same function as 20261115080000_w11-h_database.sql, minus hidden posts.
create or replace function public.following_feed(before timestamptz default null, lim int default 20)
returns setof public.posts
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select po.*
  from public.posts po
  join public.follows f on f.followee_id = po.author_id and f.follower_id = auth.uid()
  where auth.uid() is not null
    and not public.is_blocked_pair(po.author_id, auth.uid())
    and public.content_visible(po.author_id, po.hidden_at)
    and not exists (select 1 from public.feed_hidden h
                    where h.user_id = auth.uid() and h.post_id = po.id)
    and (before is null or po.created_at < following_feed.before)
  order by po.created_at desc, po.id
  limit least(greatest(coalesce(following_feed.lim, 20), 1), 50);
$$;

revoke execute on function public.following_feed(timestamptz, int) from public, anon;
grant execute on function public.following_feed(timestamptz, int) to authenticated, service_role;
