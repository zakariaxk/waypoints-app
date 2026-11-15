-- W10-8: reactions (MSG-11) and mute (SAFE-12).
--
-- message_reactions: one row per (message, user, reaction); the reaction is one of six fixed
-- keys. Readable wherever the message is readable (the read policy selects from `messages`, so
-- messages_read decides), minus reactions from suspended accounts and blocked pairs. Insert
-- and delete your own only; no update. A reaction notifies nobody: there is no trigger.
-- Not in the realtime publication: counts load with each message page and on reload.
--
-- mutes: owner-only. target_kind 'user' | 'thread' | 'channel' | 'team', `until` null means
-- until turned back on. A muted source writes no Activity row (record_notification) and sends
-- no push (the gateway's push.Service.Send asks is_muted per recipient). Nothing is hidden and
-- nobody else can read the table.

set search_path = public, extensions;

-- MSG-11 ---------------------------------------------------------------------

create table public.message_reactions (
  message_id bigint not null references public.messages (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  reaction   text not null check (reaction in ('fire', 'heart', 'thumbs_up', 'laugh', 'flag', 'wrench')),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, reaction)
);

alter table public.message_reactions enable row level security;
revoke all on public.message_reactions from anon, authenticated;
grant select, insert, delete on public.message_reactions to authenticated;

create trigger suspended_write_guard before insert or update on public.message_reactions
  for each row execute function public.suspended_write_guard();

create policy message_reactions_read on public.message_reactions
  for select to authenticated
  using (
    exists (select 1 from public.messages m where m.id = message_id)
    and (user_id = auth.uid()
         or (not public.is_suspended(user_id) and not public.is_blocked_pair(user_id, auth.uid())))
  );
create policy message_reactions_insert_own on public.message_reactions
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (
      select 1 from public.messages m
       where m.id = message_id and m.deleted_at is null
         and not public.is_blocked_pair(m.author_id, auth.uid()))
  );
create policy message_reactions_delete_own on public.message_reactions
  for delete to authenticated
  using (user_id = auth.uid());

-- Counts for one page of messages (at most 100 ids): one row per message and reaction.
-- Security invoker, so message_reactions_read applies.
create function public.message_reaction_counts(p_messages bigint[])
returns table (message_id bigint, reaction text, total int, mine boolean)
language sql stable
set search_path = public, extensions, pg_temp
as $$
  select r.message_id, r.reaction, count(*)::int, coalesce(bool_or(r.user_id = auth.uid()), false)
    from public.message_reactions r
   where r.message_id = any (p_messages[1:100])
   group by r.message_id, r.reaction;
$$;
revoke execute on function public.message_reaction_counts(bigint[]) from public, anon;
grant execute on function public.message_reaction_counts(bigint[]) to authenticated;

-- SAFE-12 --------------------------------------------------------------------

create table public.mutes (
  owner_id    uuid not null references public.profiles (user_id) on delete cascade,
  target_kind text not null check (target_kind in ('user', 'thread', 'channel', 'team')),
  target_id   uuid not null,
  until       timestamptz,
  created_at  timestamptz not null default now(),
  primary key (owner_id, target_kind, target_id)
);

alter table public.mutes enable row level security;
revoke all on public.mutes from anon, authenticated;
grant select, insert, update, delete on public.mutes to authenticated;

create trigger suspended_write_guard before insert or update on public.mutes
  for each row execute function public.suspended_write_guard();

create policy mutes_owner on public.mutes
  for all to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- Has p_owner muted the source of a notification? The source is the actor (a muted person)
-- or the subject link: a muted thread or channel, or a channel or meet of a muted team.
create function public.is_muted(p_owner uuid, p_actor uuid, p_url text)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select exists (
    select 1 from public.mutes m
     where m.owner_id = p_owner
       and (m.until is null or m.until > now())
       and case m.target_kind
             when 'user' then m.target_id = p_actor
             when 'thread' then p_url = 'waypoints://thread/' || m.target_id::text
             when 'channel' then p_url = 'waypoints://channel/' || m.target_id::text
             else p_url = 'waypoints://team/' || m.target_id::text
               or exists (select 1 from public.channels c
                           where c.team_id = m.target_id and p_url = 'waypoints://channel/' || c.id::text)
               or exists (select 1 from public.meets e
                           where e.team_id = m.target_id and p_url = 'waypoints://meet/' || e.id::text)
           end);
$$;
revoke all on function public.is_muted(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.is_muted(uuid, uuid, text) to service_role;

-- The one place an Activity row is written per recipient (W7-2), unchanged except that a
-- recipient who muted the source gets no row, and so no push from the triggers that push only
-- when a row was written.
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
  if public.is_muted(p_user, p_actor, p_url) then
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

-- The unread-count RPC (W11-H) skips channels the caller muted, directly or through their
-- team. Signature and grants are unchanged; everything else about the count is the same.
create or replace function public.channel_unread()
returns table (channel_id uuid, unread_count int)
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  with my_channels as (
    select c.id as channel_id, c.team_id
    from public.channels c
    join public.team_members m on m.team_id = c.team_id and m.user_id = auth.uid()
  ),
  reads as (
    select channel_id, last_read_message_id
    from public.read_markers
    where user_id = auth.uid() and channel_id is not null
  )
  select mc.channel_id, count(*)::int as unread_count
  from my_channels mc
  join public.messages msg on msg.channel_id = mc.channel_id
    and msg.deleted_at is null
    and msg.author_id <> auth.uid()
    and msg.id > coalesce((select r.last_read_message_id from reads r where r.channel_id = mc.channel_id), 0)
    and public.content_visible(msg.author_id, msg.hidden_at)
    and not public.is_blocked_pair(msg.author_id, auth.uid())
    and not exists (
      select 1 from public.mutes mu
      where mu.owner_id = auth.uid()
        and (mu.until is null or mu.until > now())
        and ((mu.target_kind = 'channel' and mu.target_id = mc.channel_id)
          or (mu.target_kind = 'team' and mu.target_id = mc.team_id)))
  group by mc.channel_id;
$$;
