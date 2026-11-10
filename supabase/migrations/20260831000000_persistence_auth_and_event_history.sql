-- Durable social/session metadata only. Live locations, presence, voice and replay stay in process memory.
create schema if not exists private;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) between 1 and 30),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.friendships (
  requester_id uuid not null references public.profiles(user_id) on delete cascade,
  addressee_id uuid not null references public.profiles(user_id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'blocked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);

create table if not exists public.session_metadata (
  session_id uuid primary key,
  join_code text not null check (join_code ~ '^[A-Z0-9]{6}$'),
  host_user_id uuid not null references public.profiles(user_id) on delete restrict,
  created_at timestamptz not null default now(),
  ended_at timestamptz
);

create table if not exists public.session_memberships (
  session_id uuid not null references public.session_metadata(session_id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  participant_id uuid not null,
  display_name text check (display_name is null or char_length(display_name) between 1 and 30),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (session_id, user_id),
  unique (session_id, participant_id)
);

create table if not exists public.session_events (
  id bigint generated always as identity primary key,
  session_id uuid not null references public.session_metadata(session_id) on delete cascade,
  actor_user_id uuid not null references public.profiles(user_id) on delete restrict,
  event_id bigint not null check (event_id > 0),
  kind text not null check (kind in ('PARTICIPANT_JOINED', 'PARTICIPANT_LEFT', 'DESTINATION_SET', 'DESTINATION_CLEARED', 'CHAT_MESSAGE')),
  payload jsonb not null,
  occurred_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (session_id, event_id)
);

create index if not exists session_memberships_user_id_idx on public.session_memberships(user_id);
create index if not exists session_events_session_id_event_id_idx on public.session_events(session_id, event_id);
create index if not exists friendships_addressee_id_idx on public.friendships(addressee_id);

-- Private helper prevents recursive policies while still binding every lookup to auth.uid().
create or replace function private.is_session_member(target_session_id uuid)
returns boolean language sql security definer set search_path = '' stable as $$
  select exists (
    select 1 from public.session_memberships m
    where m.session_id = target_session_id and m.user_id = (select auth.uid())
  );
$$;
revoke all on function private.is_session_member(uuid) from public;
grant usage on schema private to authenticated;
grant execute on function private.is_session_member(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.session_metadata enable row level security;
alter table public.session_memberships enable row level security;
alter table public.session_events enable row level security;

revoke all on public.profiles, public.friendships, public.session_metadata, public.session_memberships, public.session_events from anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.friendships to authenticated;
grant select on public.session_metadata, public.session_memberships, public.session_events to authenticated;
grant all on public.profiles, public.friendships, public.session_metadata, public.session_memberships, public.session_events to service_role;
grant usage, select on all sequences in schema public to service_role;

create policy "profiles self select" on public.profiles for select to authenticated using ((select auth.uid()) = user_id);
create policy "profiles self insert" on public.profiles for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "profiles self update" on public.profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "friendships participants select" on public.friendships for select to authenticated using ((select auth.uid()) in (requester_id, addressee_id));
create policy "friendships requester insert" on public.friendships for insert to authenticated with check ((select auth.uid()) = requester_id);
create policy "friendships addressee update" on public.friendships for update to authenticated using ((select auth.uid()) = addressee_id) with check ((select auth.uid()) in (requester_id, addressee_id));

create policy "session metadata members select" on public.session_metadata for select to authenticated using (private.is_session_member(session_id));
create policy "session memberships members select" on public.session_memberships for select to authenticated using (private.is_session_member(session_id));
create policy "session events members select" on public.session_events for select to authenticated using (private.is_session_member(session_id));

-- Service-only persistence is asynchronous; clients never write server event history directly.
