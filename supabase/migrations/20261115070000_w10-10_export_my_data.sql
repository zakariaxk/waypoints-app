-- W10-10: "Download my data" (ACC-12).
-- One document of everything the caller owns. Only rows keyed to auth.uid() are read;
-- other people appear only as an id and a handle (friends, follows, blocks). Messages are
-- the caller's own rows, never the ones received. Left out on purpose: device_tokens,
-- notifications (they quote other people), convoys, read_markers, user_presence_cell.

set search_path = public, extensions;

create function public.export_my_data()
returns jsonb
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_me uuid := auth.uid();
begin
  if v_me is null then
    raise exception 'Sign in to download your data' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from profiles p where p.user_id = v_me),
    'privacy_settings', (select to_jsonb(s) from privacy_settings s where s.user_id = v_me),
    'notification_settings', (select to_jsonb(n) from notification_prefs n where n.user_id = v_me),
    'cars', coalesce((
      select jsonb_agg(to_jsonb(c) || jsonb_build_object(
        'photos', coalesce((select jsonb_agg(to_jsonb(ph) order by ph.sort)
                            from car_photos ph where ph.car_id = c.id), '[]'::jsonb),
        'timeline', coalesce((select jsonb_agg(to_jsonb(e) order by e.happened_on, e.created_at)
                              from build_entries e where e.car_id = c.id), '[]'::jsonb),
        'showdown', (select to_jsonb(se) from showdown_entries se where se.car_id = c.id)
      ) order by c.sort, c.created_at)
      from cars c where c.owner_id = v_me), '[]'::jsonb),
    'posts', coalesce((
      select jsonb_agg(to_jsonb(p) || jsonb_build_object(
        'photos', coalesce((select jsonb_agg(pp.path order by pp.sort)
                            from post_photos pp where pp.post_id = p.id), '[]'::jsonb)
      ) order by p.created_at)
      from posts p where p.author_id = v_me), '[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(to_jsonb(pc) order by pc.created_at)
      from post_comments pc where pc.author_id = v_me), '[]'::jsonb),
    'liked_post_ids', coalesce((
      select jsonb_agg(pl.post_id order by pl.created_at)
      from post_likes pl where pl.user_id = v_me), '[]'::jsonb),
    'listings', coalesce((
      select jsonb_agg(to_jsonb(l) || jsonb_build_object(
        'photos', coalesce((select jsonb_agg(lp.path order by lp.sort)
                            from listing_photos lp where lp.listing_id = l.id), '[]'::jsonb)
      ) order by l.created_at)
      from listings l where l.seller_id = v_me), '[]'::jsonb),
    'saved_listing_ids', coalesce((
      select jsonb_agg(ls.listing_id order by ls.created_at)
      from listing_saves ls where ls.user_id = v_me), '[]'::jsonb),
    'messages', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.id)
      from messages m where m.author_id = v_me and m.deleted_at is null), '[]'::jsonb),
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id', o.user_id, 'handle', o.handle, 'status', f.status,
        'requested_by_me', f.requester_id = v_me, 'created_at', f.created_at) order by f.created_at)
      from friendships f
      join profiles o on o.user_id = case when f.requester_id = v_me then f.addressee_id else f.requester_id end
      where v_me in (f.requester_id, f.addressee_id)), '[]'::jsonb),
    'following', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', o.user_id, 'handle', o.handle, 'created_at', f.created_at)
                       order by f.created_at)
      from follows f join profiles o on o.user_id = f.followee_id
      where f.follower_id = v_me), '[]'::jsonb),
    'followers', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', o.user_id, 'handle', o.handle, 'created_at', f.created_at)
                       order by f.created_at)
      from follows f join profiles o on o.user_id = f.follower_id
      where f.followee_id = v_me), '[]'::jsonb),
    'blocks', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', o.user_id, 'handle', o.handle, 'created_at', b.created_at)
                       order by b.created_at)
      from blocks b join profiles o on o.user_id = b.blocked_id
      where b.blocker_id = v_me), '[]'::jsonb),
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'team_id', t.id, 'name', t.name, 'tag', t.tag, 'owner', t.owner_id = v_me,
        'role', r.name, 'joined_at', tm.joined_at) order by tm.joined_at)
      from team_members tm
      join teams t on t.id = tm.team_id
      left join team_roles r on r.id = tm.role_id
      where tm.user_id = v_me), '[]'::jsonb),
    'meets_hosted', coalesce((
      select jsonb_agg((to_jsonb(m) - 'geom') || jsonb_build_object(
        'lat', st_y(m.geom::geometry), 'lng', st_x(m.geom::geometry)) order by m.starts_at)
      from meets m where m.host_id = v_me), '[]'::jsonb),
    'rsvps', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.created_at)
      from meet_rsvps r where r.user_id = v_me), '[]'::jsonb),
    'meet_checkins', coalesce((
      select jsonb_agg(to_jsonb(mc) order by mc.created_at)
      from meet_checkins mc where mc.user_id = v_me), '[]'::jsonb),
    'meet_votes', coalesce((
      select jsonb_agg(to_jsonb(mv) order by mv.created_at)
      from meet_votes mv where mv.voter_id = v_me), '[]'::jsonb),
    'spots', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.created_at)
      from spots s where s.spotter_id = v_me), '[]'::jsonb),
    'saved_roads', coalesce((
      select jsonb_agg((to_jsonb(r) - 'path') || jsonb_build_object('path', st_asgeojson(r.path)::jsonb)
                       order by r.created_at)
      from roads r where r.author_id = v_me), '[]'::jsonb),
    'road_loops', coalesce((
      select jsonb_agg(to_jsonb(rl) order by rl.created_at)
      from road_loops rl where rl.owner_id = v_me), '[]'::jsonb),
    'road_ratings', coalesce((
      select jsonb_agg(to_jsonb(rr) order by rr.created_at)
      from road_ratings rr where rr.user_id = v_me), '[]'::jsonb),
    'race_results', coalesce((
      select jsonb_agg(to_jsonb(rr) - 'input_log' order by rr.created_at)
      from race_results rr where rr.user_id = v_me), '[]'::jsonb),
    'showdown_votes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'winner_car_id', sv.winner_car_id, 'loser_car_id', sv.loser_car_id, 'created_at', sv.created_at)
        order by sv.created_at)
      from showdown_votes sv where sv.voter_id = v_me), '[]'::jsonb),
    'achievements', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.earned_at)
      from achievements a where a.user_id = v_me), '[]'::jsonb),
    'map_reports', coalesce((
      select jsonb_agg((to_jsonb(r) - 'geom') || jsonb_build_object(
        'lat', st_y(r.geom::geometry), 'lng', st_x(r.geom::geometry)) order by r.created_at)
      from reports r where r.author_id = v_me), '[]'::jsonb),
    'map_report_votes', coalesce((
      select jsonb_agg(to_jsonb(rv) order by rv.created_at)
      from report_votes rv where rv.user_id = v_me), '[]'::jsonb),
    'venue_notes', coalesce((
      select jsonb_agg((to_jsonb(v) - 'geom') || jsonb_build_object(
        'lat', st_y(v.geom::geometry), 'lng', st_x(v.geom::geometry)) order by v.created_at)
      from venue_notes v where v.author_id = v_me), '[]'::jsonb),
    'help_requests', coalesce((
      select jsonb_agg((to_jsonb(h) - 'geom') || jsonb_build_object(
        'lat', st_y(h.geom::geometry), 'lng', st_x(h.geom::geometry)) order by h.created_at)
      from help_requests h where h.requester_id = v_me), '[]'::jsonb),
    'help_responses', coalesce((
      select jsonb_agg(jsonb_build_object('request_id', hr.request_id, 'created_at', hr.created_at)
                       order by hr.created_at)
      from help_responses hr where hr.user_id = v_me), '[]'::jsonb),
    'content_reports', coalesce((
      select jsonb_agg(jsonb_build_object(
        'target_kind', cr.target_kind, 'target_id', cr.target_id, 'reason', cr.reason,
        'note', cr.note, 'created_at', cr.created_at) order by cr.created_at)
      from content_reports cr where cr.reporter_id = v_me), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;
