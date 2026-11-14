-- W6-8 (FEED-2): "For you" is recency plus likes within the viewer's region, then everywhere.
--
-- Region, in this order:
--   1. the same profiles.home_region (case and outer spaces ignored), or
--   2. the same H3 resolution-4 parent (about 1,770 km²) of the author's and the viewer's last
--      presence cell (user_presence_cell.h3_r7, written by the gateway).
-- Inside each tier the score is stated, not hidden: ln(1 + likes) minus age in days, so a post
-- with about 2.7 times the likes ranks level with one a day newer. Blocked pairs never appear.
-- Paging is by offset: the client passes the offset back as its cursor and drops repeats.

-- The resolution-4 parent of an H3 cell, by bit arithmetic (no H3 extension here): set the
-- resolution field (bits 52-55) to 4 and every digit below it (bits 0-32) to 7.
create or replace function public.h3_parent_r4(cell bigint)
returns bigint
language sql immutable parallel safe
set search_path = public, pg_temp
as $$
  select case
    when cell is null then null
    when ((cell >> 52) & 15) <= 4 then cell
    else (cell & ~((15::bigint << 52) | ((1::bigint << 33) - 1)))
         | (4::bigint << 52)
         | ((1::bigint << 33) - 1)
  end;
$$;

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

revoke all on function public.h3_parent_r4(bigint) from public, anon;
grant execute on function public.h3_parent_r4(bigint) to authenticated, service_role;
revoke all on function public.feed_for_you(int, int) from public, anon;
grant execute on function public.feed_for_you(int, int) to authenticated, service_role;
