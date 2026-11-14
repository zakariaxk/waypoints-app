-- Waypoints moderation runbook (SAFE-6 to SAFE-8, CMP-3).
--
-- Review content_reports within 24 hours of each report. There is no admin
-- app: open the Supabase dashboard, SQL editor, and run the statements below
-- one at a time. The SQL editor runs as postgres; the four functions are also
-- callable with the service role key, and by nobody else.
--
-- The functions live in migration 20261113100100_w7-1_moderation.sql:
--
--   moderation_hide(kind, target_id)     hide a thing now, close its reports
--   moderation_restore(kind, target_id)  show it again, close its reports
--   moderation_suspend(user_id_or_handle)    suspend an account
--   moderation_unsuspend(user_id_or_handle)  lift a suspension
--
-- kind is content_reports.target_kind: user, car, post, comment, message,
-- listing, meet, report, team, spot, road. target_id is
-- content_reports.target_id (a uuid, or a number for messages; for user it is
-- the user id).
--
-- What happens on its own:
--   * Three different people reporting the same thing within 7 days sets its
--     hidden_at. It disappears for everyone except its author until you hide
--     (keep it hidden) or restore it.
--   * A suspended account cannot insert or update any row or upload media, the
--     gateway refuses its tokens within a minute, its profile, cars, and
--     content are hidden from everyone else, and signing in shows "This
--     account is suspended." with support@waypoints.app.


-- 1. The queue: open reports, grouped by target, oldest first ---------------

select r.target_kind,
       r.target_id,
       count(distinct r.reporter_id)        as reporters,
       array_agg(distinct r.reason::text)   as reasons,
       min(r.created_at)                    as first_reported,
       string_agg(nullif(r.note, ''), ' | ') as notes
from public.content_reports r
where r.resolved_at is null
group by r.target_kind, r.target_id
order by min(r.created_at);


-- 2. Look at the thing (swap in the target_id) -------------------------------

-- select * from public.posts         where id = '<target_id>';
-- select * from public.post_comments where id = '<target_id>';
-- select * from public.messages      where id = <target_id>;
-- select * from public.listings      where id = '<target_id>';
-- select * from public.meets         where id = '<target_id>';
-- select * from public.reports       where id = '<target_id>';
-- select * from public.teams         where id = '<target_id>';
-- select * from public.spots         where id = '<target_id>';
-- select * from public.roads         where id = '<target_id>';
-- select * from public.cars          where id = '<target_id>';
-- select * from public.profiles      where user_id = '<target_id>';

-- Who wrote it, and how often they have been reported:
-- select p.user_id, p.handle, p.suspended_at, count(r.id) as reports_against
-- from public.profiles p
-- left join public.content_reports r on r.target_kind = 'user' and r.target_id = p.user_id::text
-- where p.handle = '<handle>'
-- group by p.user_id;


-- 3. Act ---------------------------------------------------------------------

-- It breaks the rules: keep it hidden.
-- select public.moderation_hide('post', '<target_id>');

-- It is fine: show it again.
-- select public.moderation_restore('post', '<target_id>');

-- The person breaks the rules: suspend them (by handle or user id).
-- select public.moderation_suspend('<handle>');

-- Lift a suspension.
-- select public.moderation_unsuspend('<handle>');


-- 4. State -------------------------------------------------------------------

-- Everything hidden right now:
-- select 'post' as kind, id::text, author_id, hidden_at from public.posts where hidden_at is not null
-- union all select 'comment', id::text, author_id, hidden_at from public.post_comments where hidden_at is not null
-- union all select 'message', id::text, author_id, hidden_at from public.messages where hidden_at is not null
-- union all select 'listing', id::text, seller_id, hidden_at from public.listings where hidden_at is not null
-- union all select 'meet', id::text, host_id, hidden_at from public.meets where hidden_at is not null
-- union all select 'report', id::text, author_id, hidden_at from public.reports where hidden_at is not null
-- union all select 'team', id::text, owner_id, hidden_at from public.teams where hidden_at is not null
-- union all select 'spot', id::text, spotter_id, hidden_at from public.spots where hidden_at is not null
-- union all select 'road', id::text, author_id, hidden_at from public.roads where hidden_at is not null
-- union all select 'car', id::text, owner_id, hidden_at from public.cars where hidden_at is not null
-- union all select 'user', user_id::text, user_id, hidden_at from public.profiles where hidden_at is not null
-- order by hidden_at;

-- Suspended accounts:
-- select user_id, handle, suspended_at from public.profiles where suspended_at is not null order by suspended_at;
