-- MEET-17: discussion comments on a meet. Mirrors post_comments; reads are open
-- like there, inserts require meet visibility (can_read_meet), deletes are the
-- author's or the meet host's.

create table public.meet_comments (
  id         uuid primary key default gen_random_uuid(),
  meet_id    uuid not null references public.meets (id) on delete cascade,
  author_id  uuid not null references public.profiles (user_id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index meet_comments_meet_idx on public.meet_comments (meet_id, created_at);
create index meet_comments_author_created_idx on public.meet_comments (author_id, created_at);

alter table public.meet_comments enable row level security;

create policy meet_comments_read on public.meet_comments
  for select to authenticated
  using (true);
create policy meet_comments_insert on public.meet_comments
  for insert to authenticated
  with check (author_id = auth.uid() and public.can_read_meet(meet_id));
create policy meet_comments_delete on public.meet_comments
  for delete to authenticated
  using (author_id = auth.uid()
         or exists (select 1 from public.meets m
                    where m.id = meet_id and m.host_id = auth.uid()));

create trigger abuse_limit before insert on public.meet_comments
  for each row execute function public.abuse_limit('author_id', '30', '1 hour');
create trigger clean_text_guard before insert or update on public.meet_comments
  for each row execute function public.clean_text_guard('body');

-- Same pins as post_comments: no updates, column-scoped insert grant.
revoke update on public.meet_comments from authenticated;
revoke insert on public.meet_comments from authenticated;
grant insert (meet_id, author_id, body) on public.meet_comments to authenticated;
