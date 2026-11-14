-- W8-1C (FEED-2, PRD 2.1 rule 1): feed_for_you ranked posts up when the author's coarse
-- presence cell was near the viewer's, so page order leaked which authors are nearby.
-- Same function as 20261113190000_w7-1_moderate_feed_for_you.sql (blocked-pair exclusion and
-- the content_visible moderation rule unchanged), ranked by home_region text match only.

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
  order by
    coalesce(v.region is not null and nullif(lower(btrim(a.home_region)), '') = v.region, false) desc,
    ln(1 + po.like_count) - extract(epoch from (now() - po.created_at)) / 86400.0 desc,
    po.created_at desc,
    po.id
  offset greatest(coalesce(feed_for_you.after, 0), 0)
  limit least(greatest(coalesce(feed_for_you.lim, 10), 1), 50);
$$;
