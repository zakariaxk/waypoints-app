-- W2-1: convoy mirror (plan section 7.6). The gateway keeps convoys in memory
-- and writes the whole state here on each change so any node can load it.

create table public.convoys (
  id         text primary key,
  join_code  text not null unique,
  state      jsonb not null,
  ended      boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index convoys_live_idx on public.convoys (join_code) where not ended;

alter table public.convoys enable row level security;
revoke all on public.convoys from anon, authenticated;
