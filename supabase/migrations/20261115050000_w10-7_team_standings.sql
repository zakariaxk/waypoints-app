-- W10-7 (TEAM-11): team standings.
--
-- A team's score for the week is the number of Showdown votes its current members' cars won
-- since Monday 00:00 UTC (the same week as showdown_week_top and the weekly close). Votes only:
-- nothing from driving, distance, or the Strip. Hidden cars, cars of suspended owners, and
-- hidden teams drop out, as they do in showdown_week_top and teams_read.
--
-- team_standings() is security definer because showdown_votes is readable only by the voter.
-- It returns team id, name, tag, icon, score and rank, never a vote or a voter. Rank is over
-- every scoring team, so a team's rank is the same for every caller. Rows returned: the
-- caller's own teams, and public teams in the top 100 (plus the public team named in `team`,
-- for the team page).
--
-- No new index: the week is read through showdown_votes_created_idx, cars by primary key, and
-- memberships through team_members_user_idx.

create function public.team_standings(team uuid default null)
returns table (team_id uuid, name text, tag text, icon_path text, score int, rank int)
language sql stable security definer
set search_path = public, pg_temp
as $$
  with bounds as (
    select date_trunc('week', now() at time zone 'utc') at time zone 'utc' as s
  ),
  scored as (
    select m.team_id, count(*)::int as score
    from public.showdown_votes v
    join public.cars c on c.id = v.winner_car_id
    join public.team_members m on m.user_id = c.owner_id
    cross join bounds b
    where v.created_at >= b.s
      and v.created_at < b.s + interval '7 days'
      and c.hidden_at is null
      and not public.is_suspended(c.owner_id)
    group by m.team_id
  ),
  ranked as (
    select t.id, t.name, t.tag, t.icon_path, t.is_public, s.score,
           (rank() over (order by s.score desc))::int as rank
    from scored s
    join public.teams t on t.id = s.team_id
    where t.hidden_at is null
  )
  select r.id, r.name, r.tag, r.icon_path, r.score, r.rank
  from ranked r
  where public.is_team_member(r.id)
     or (r.is_public and (r.rank <= 100 or r.id = team_standings.team))
  order by r.rank, r.name;
$$;

revoke all on function public.team_standings(uuid) from public, anon;
grant execute on function public.team_standings(uuid) to authenticated, service_role;
