-- W7-4 (PRD HELP-1..7): help requests. Written only by the gateway (POST/DELETE /v1/help,
-- PUT /v1/help/{id}/extend, POST /v1/help/{id}/respond), which also fans them out over the
-- realtime MapEvent kind HELP. The exact point is stored because the requester chose to share
-- it (HELP-3); a row is ended when the requester clears it or 60 minutes pass without an
-- extension, and the gateway serves only active rows.

set search_path = public, extensions;

create type public.help_kind as enum ('flat_tire', 'jump_start', 'out_of_fuel', 'stuck', 'other');

create table public.help_requests (
  id           uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (user_id) on delete cascade,
  kind         public.help_kind not null,
  geom         geography(Point, 4326) not null,
  h3_r7        bigint,
  note         text check (char_length(note) <= 120),
  show_nearby  boolean not null default false,
  expires_at   timestamptz not null default now() + interval '60 minutes',
  ended_at     timestamptz,
  created_at   timestamptz not null default now()
);
-- One active request per person (HELP-6).
create unique index help_requests_one_active on public.help_requests (requester_id) where ended_at is null;
create index help_requests_active_geom on public.help_requests using gist (geom) where ended_at is null;
create index help_requests_expires on public.help_requests (expires_at) where ended_at is null;

create table public.help_responses (
  request_id uuid not null references public.help_requests (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (request_id, user_id)
);

alter table public.help_requests enable row level security;
alter table public.help_responses enable row level security;

-- Reads: the requester, and their friends and teammates while it is active. The anonymous
-- nearby form is served only by the gateway, which strips the requester.
create function public.can_read_help(requester uuid)
returns boolean
language sql stable security definer
set search_path = public, extensions, pg_temp
as $$
  select auth.uid() is not null and (
    requester = auth.uid()
    or (not public.is_blocked_pair(requester, auth.uid()) and (
      public.are_friends(requester, auth.uid())
      or exists (select 1 from public.team_members a join public.team_members b on b.team_id = a.team_id
                 where a.user_id = requester and b.user_id = auth.uid())))
  );
$$;

create policy help_requests_read on public.help_requests for select to authenticated
  using (public.can_read_help(requester_id) and (requester_id = auth.uid() or (ended_at is null and expires_at > now())));

create policy help_responses_read on public.help_responses for select to authenticated
  using (user_id = auth.uid()
         or exists (select 1 from public.help_requests h where h.id = request_id and h.requester_id = auth.uid()));

revoke insert, update, delete on public.help_requests, public.help_responses from authenticated;
grant select on public.help_requests, public.help_responses to authenticated;
