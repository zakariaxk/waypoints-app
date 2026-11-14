-- W7-1 (SAFE-6, SAFE-7): feed_for_you is security definer, so it bypasses the posts_read
-- policy. Same function as 20261113160000_w6-8_feed_for_you.sql, plus the moderation rule:
-- hidden posts and posts by suspended accounts show only to their author.

create or replace function public.feed_for_you(after int default 0, lim int default 10)
returns setof public.posts
language sql stable security definer
set search_path = public, pg_temp
as $$
  with viewer as (
    select nullif(lower(btrim(p.home_region)), '') as region,
           public.h3_parent_r4(c.h3_r7) as cell
    from public.profiles p
    left join public.user_presence_cell c on c.user_id = p.user_id
    where p.user_id = auth.uid()
  )
  select po.*
  from public.posts po
  join public.profiles a on a.user_id = po.author_id
  left join public.user_presence_cell ac on ac.user_id = po.author_id
  left join viewer v on true
  where auth.uid() is not null
    and not public.is_blocked_pair(po.author_id, auth.uid())
    and public.content_visible(po.author_id, po.hidden_at)
  order by
    coalesce(
      (v.region is not null and nullif(lower(btrim(a.home_region)), '') = v.region)
      or (v.cell is not null and public.h3_parent_r4(ac.h3_r7) = v.cell),
      false
    ) desc,
    ln(1 + po.like_count) - extract(epoch from (now() - po.created_at)) / 86400.0 desc,
    po.created_at desc,
    po.id
  offset greatest(coalesce(feed_for_you.after, 0), 0)
  limit least(greatest(coalesce(feed_for_you.lim, 10), 1), 50);
$$;
