-- L80 (KNW-8): "helpful" votes on repair guides. One row per (guide, voter): a row
-- is a vote, there are no down-votes, and changing your mind means deleting the row.
-- `repair_guides.votes_count` is trigger-maintained exactly like posts.like_count,
-- so every read pattern already in place (lists and detail) carries the count for free.
-- Votes are private to the voter (mirrors post_likes); the count is public on the guide.

create table public.guide_votes (
  guide_id   uuid not null references public.repair_guides (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (guide_id, user_id)
);
create index guide_votes_user_idx on public.guide_votes (user_id);

alter table public.repair_guides
  add column votes_count int not null default 0 check (votes_count >= 0);

alter table public.guide_votes enable row level security;

-- Owner read is required: Postgres applies SELECT policies to DELETE ... WHERE.
create policy guide_votes_read_own on public.guide_votes
  for select to authenticated
  using (user_id = auth.uid());
create policy guide_votes_insert_own on public.guide_votes
  for insert to authenticated
  with check (user_id = auth.uid());
create policy guide_votes_delete_own on public.guide_votes
  for delete to authenticated
  using (user_id = auth.uid());

revoke all on public.guide_votes from public, anon;
revoke update, truncate on public.guide_votes from authenticated;
grant select, delete on public.guide_votes to authenticated;
grant insert (guide_id, user_id) on public.guide_votes to authenticated;
-- created_at stays server-set (mirrors the W11-H column-grant pass).

create function public.guide_votes_count()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    update public.repair_guides set votes_count = votes_count + 1 where id = new.guide_id;
  else
    update public.repair_guides set votes_count = greatest(votes_count - 1, 0) where id = old.guide_id;
  end if;
  return null;
end;
$$;

create trigger guide_votes_count
  after insert or delete on public.guide_votes
  for each row execute function public.guide_votes_count();

create trigger suspended_write_guard before insert or update on public.guide_votes
  for each row execute function public.suspended_write_guard();
