-- W7-2: Activity (NTF-6, NTF-7). One `notifications` row per recipient per event, written by
-- the triggers below and by the gateway's push.Service.Send (meets nearby, meet changes,
-- convoy invites). Rows work with no APNs or gateway configured; the push is extra.
--
-- One notification per event (NTF-7): `dedupe_key` is unique per recipient, so re-liking a
-- post or re-RSVPing does not notify twice. Rows older than 90 days are deleted on insert.

create table public.notifications (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (user_id) on delete cascade,
  kind        text not null check (kind ~ '^[a-z_]{1,30}$'),
  actor_id    uuid references public.profiles (user_id) on delete cascade,
  subject_url text check (char_length(subject_url) <= 200),
  title       text not null check (char_length(title) between 1 and 120),
  body        text check (char_length(body) <= 200),
  dedupe_key  text check (char_length(dedupe_key) <= 120),
  read_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_kind_idx on public.notifications (user_id, kind, created_at desc);
create unique index notifications_dedupe_key on public.notifications (user_id, dedupe_key)
  where dedupe_key is not null;

alter table public.notifications enable row level security;
create policy notifications_owner_read on public.notifications
  for select to authenticated using (user_id = auth.uid());
create policy notifications_owner_update on public.notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- Records one row. Returns false when nothing was written: the recipient is the actor, either
-- has blocked the other, or this event was already recorded.
create or replace function public.record_notification(
  p_user uuid, p_kind text, p_actor uuid, p_url text, p_title text, p_body text, p_dedupe text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  if p_user is null or (p_actor is not null and p_actor = p_user) then
    return false;
  end if;
  if p_actor is not null and exists (
    select 1 from public.blocks b
     where (b.blocker_id = p_user and b.blocked_id = p_actor)
        or (b.blocker_id = p_actor and b.blocked_id = p_user)) then
    return false;
  end if;
  delete from public.notifications
   where user_id = p_user and created_at < now() - interval '90 days';
  insert into public.notifications (user_id, kind, actor_id, subject_url, title, body, dedupe_key)
  values (p_user, p_kind, p_actor, p_url, left(p_title, 120), left(p_body, 200), p_dedupe)
  on conflict (user_id, dedupe_key) where dedupe_key is not null do nothing;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;
revoke all on function public.record_notification(uuid, text, uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.record_notification(uuid, text, uuid, text, text, text, text)
  to service_role;

create or replace function public.actor_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select display_name from public.profiles where user_id = p_user), 'Someone');
$$;
revoke all on function public.actor_name(uuid) from public, anon, authenticated;

-- Messages: mentions are recorded per recipient; DMs stay in the inbox and only push.
create or replace function public.on_message_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  handles text[];
  recipients jsonb := '[]'::jsonb;
  r uuid;
begin
  if new.thread_id is not null then
    select * into t from public.threads where id = new.thread_id;
    perform public.notify_gateway(jsonb_build_object(
      'kind', 'dm',
      'recipient_id', case when t.a_id = new.author_id then t.b_id else t.a_id end,
      'actor_id', new.author_id, 'ref_id', new.thread_id, 'preview', left(new.body, 120)));
  elsif new.channel_id is not null and position('@' in new.body) > 0 then
    select array_agg(lower(m[1])) into handles
      from regexp_matches(new.body, '@([A-Za-z0-9_]{3,20})', 'g') as m;
    if handles is not null then
      for r in
        select p.user_id
          from public.profiles p
          join public.channels c on c.id = new.channel_id
          join public.team_members tm on tm.team_id = c.team_id and tm.user_id = p.user_id
         where lower(p.handle::text) = any (handles) and p.user_id <> new.author_id
      loop
        if public.record_notification(r, 'mention', new.author_id,
             'waypoints://channel/' || new.channel_id,
             public.actor_name(new.author_id) || ' mentioned you', left(new.body, 120),
             'mention:' || new.id) then
          recipients := recipients || to_jsonb(r);
        end if;
      end loop;
      if jsonb_array_length(recipients) > 0 then
        perform public.notify_gateway(jsonb_build_object(
          'kind', 'mention', 'recipients', recipients,
          'actor_id', new.author_id, 'ref_id', new.channel_id, 'preview', left(new.body, 120)));
      end if;
    end if;
  end if;
  return new;
end;
$$;

-- Friend requests (insert) and acceptances (update to accepted).
create or replace function public.on_friend_request_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'pending' then
    if public.record_notification(new.addressee_id, 'friend_request', new.requester_id,
         'waypoints://profile/' || new.requester_id, 'Friend request',
         public.actor_name(new.requester_id) || ' wants to be friends.',
         'friend_request:' || new.requester_id) then
      perform public.notify_gateway(jsonb_build_object(
        'kind', 'friend_request', 'recipient_id', new.addressee_id, 'actor_id', new.requester_id));
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.on_friend_accept_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'accepted' and old.status is distinct from 'accepted' then
    perform public.record_notification(new.requester_id, 'friend_accepted', new.addressee_id,
      'waypoints://profile/' || new.addressee_id, 'Friend request accepted',
      public.actor_name(new.addressee_id) || ' accepted your friend request.',
      'friend_accepted:' || new.addressee_id);
  end if;
  return new;
end;
$$;
create trigger friendships_accept_notify after update of status on public.friendships
  for each row execute function public.on_friend_accept_notify();

-- Likes and comments on your posts.
create or replace function public.on_post_like_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  p record;
begin
  select author_id, caption into p from public.posts where id = new.post_id;
  if found then
    perform public.record_notification(p.author_id, 'like', new.user_id,
      'waypoints://post/' || new.post_id, public.actor_name(new.user_id) || ' liked your post',
      p.caption, 'like:' || new.post_id || ':' || new.user_id);
  end if;
  return new;
end;
$$;
create trigger post_likes_notify after insert on public.post_likes
  for each row execute function public.on_post_like_notify();

create or replace function public.on_post_comment_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  author uuid;
begin
  select author_id into author from public.posts where id = new.post_id;
  if found then
    perform public.record_notification(author, 'comment', new.author_id,
      'waypoints://post/' || new.post_id, public.actor_name(new.author_id) || ' commented on your post',
      left(new.body, 120), 'comment:' || new.id);
  end if;
  return new;
end;
$$;
create trigger post_comments_notify after insert on public.post_comments
  for each row execute function public.on_post_comment_notify();

-- RSVPs to a meet you host.
create or replace function public.on_rsvp_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m record;
begin
  select host_id, title into m from public.meets where id = new.meet_id;
  if found then
    perform public.record_notification(m.host_id, 'rsvp', new.user_id,
      'waypoints://meet/' || new.meet_id,
      public.actor_name(new.user_id) || case when new.status = 'maybe' then ' might come' else ' is going' end,
      m.title, 'rsvp:' || new.meet_id || ':' || new.user_id);
  end if;
  return new;
end;
$$;
create trigger meet_rsvps_notify after insert on public.meet_rsvps
  for each row execute function public.on_rsvp_notify();

-- Achievements earned (each new key unlocks a marker, plan 9.8).
create or replace function public.on_achievement_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.record_notification(new.user_id, 'unlock', null,
    'waypoints://profile/' || new.user_id, 'New marker earned',
    null, 'unlock:' || new.key);
  return new;
end;
$$;
create trigger achievements_notify after insert on public.achievements
  for each row execute function public.on_achievement_notify();
