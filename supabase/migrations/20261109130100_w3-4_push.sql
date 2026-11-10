-- W3-4: notification preferences (S3) and pg_net triggers that call the
-- gateway's POST /internal/notify for DMs, mentions, and friend requests.
--
-- The triggers read two database settings, set once per project:
--   alter database postgres set app.gateway_url = 'https://gateway.example.com';
--   alter database postgres set app.internal_secret = '<WAYPOINTS_INTERNAL_SECRET>';
-- With either unset they do nothing.

create extension if not exists pg_net with schema extensions;

create table public.notification_prefs (
  user_id         uuid primary key references public.profiles (user_id) on delete cascade,
  friend_requests boolean not null default true,
  messages        boolean not null default true,
  mentions        boolean not null default true,
  convoy_invites  boolean not null default true,
  meet_reminders  boolean not null default true,
  meets_nearby    boolean not null default true,
  created_at      timestamptz not null default now()
);

alter table public.notification_prefs enable row level security;
create policy notification_prefs_owner on public.notification_prefs
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update on public.notification_prefs to authenticated;

create or replace function public.notify_gateway(payload jsonb)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  url    text := current_setting('app.gateway_url', true);
  secret text := current_setting('app.internal_secret', true);
begin
  if coalesce(url, '') = '' or coalesce(secret, '') = '' then
    return;
  end if;
  perform net.http_post(
    url := url || '/internal/notify',
    body := payload,
    headers := jsonb_build_object('Content-Type', 'application/json', 'X-Waypoints-Secret', secret)
  );
end;
$$;
revoke all on function public.notify_gateway(jsonb) from public, anon, authenticated;

create or replace function public.on_message_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t record;
  handles text[];
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
      perform public.notify_gateway(jsonb_build_object(
        'kind', 'mention',
        'recipients', (select coalesce(jsonb_agg(p.user_id), '[]'::jsonb)
                         from public.profiles p
                         join public.channels c on c.id = new.channel_id
                         join public.team_members tm on tm.team_id = c.team_id and tm.user_id = p.user_id
                        where lower(p.handle::text) = any (handles) and p.user_id <> new.author_id),
        'actor_id', new.author_id, 'ref_id', new.channel_id, 'preview', left(new.body, 120)));
    end if;
  end if;
  return new;
end;
$$;

create trigger messages_notify after insert on public.messages
  for each row execute function public.on_message_notify();

create or replace function public.on_friend_request_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'pending' then
    perform public.notify_gateway(jsonb_build_object(
      'kind', 'friend_request', 'recipient_id', new.addressee_id, 'actor_id', new.requester_id));
  end if;
  return new;
end;
$$;

create trigger friendships_notify after insert on public.friendships
  for each row execute function public.on_friend_request_notify();
