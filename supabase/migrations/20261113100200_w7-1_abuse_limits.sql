-- W7-1: abuse limits on direct table inserts (SAFE-9).
--
-- A before-insert trigger counts the caller's own rows in a trailing window
-- and refuses the insert past the limit with SQLSTATE PT429, which PostgREST
-- returns as HTTP 429 and the client shows as "You're doing that a lot. Try
-- again in a few minutes."
--
-- Only end users' own top-level inserts are counted (auth.uid() set, the row's
-- actor is the caller, pg_trigger_depth() = 1). Meets and map reports are
-- written by the gateway, which enforces their limits (3 meets a day, 10
-- reports in 10 minutes). Help requests have no table yet; whoever adds one
-- attaches this trigger with ('<actor column>', '3', '1 day').

set search_path = public, extensions;

create function public.abuse_limit()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_column text := tg_argv[0];
  v_max    int := tg_argv[1]::int;
  v_window interval := tg_argv[2]::interval;
  v_actor  uuid;
  v_count  int;
begin
  if pg_trigger_depth() <> 1 or auth.uid() is null then
    return new;
  end if;
  v_actor := (to_jsonb(new) ->> v_column)::uuid;
  if v_actor is distinct from auth.uid() then
    return new;
  end if;
  execute format(
    'select count(*) from (select 1 from %I.%I where %I = $1 and created_at > now() - $2 limit $3) t',
    tg_table_schema, tg_table_name, v_column
  ) into v_count using v_actor, v_window, v_max;
  if v_count >= v_max then
    raise exception 'rate_limited'
      using errcode = 'PT429',
            hint = format('%s: at most %s per %s', tg_table_name, v_max, v_window);
  end if;
  return new;
end;
$$;

revoke execute on function public.abuse_limit() from public, anon, authenticated;

create index if not exists posts_author_created_idx on public.posts (author_id, created_at);
create index if not exists post_comments_author_created_idx on public.post_comments (author_id, created_at);
create index if not exists listings_seller_created_idx on public.listings (seller_id, created_at);
create index if not exists friendships_requester_created_idx on public.friendships (requester_id, created_at);
create index if not exists teams_owner_created_idx on public.teams (owner_id, created_at);
create index if not exists content_reports_reporter_created_idx on public.content_reports (reporter_id, created_at);
create index if not exists messages_author_created_idx on public.messages (author_id, created_at);

create trigger abuse_limit before insert on public.posts
  for each row execute function public.abuse_limit('author_id', '10', '1 day');
create trigger abuse_limit before insert on public.post_comments
  for each row execute function public.abuse_limit('author_id', '30', '1 hour');
create trigger abuse_limit before insert on public.listings
  for each row execute function public.abuse_limit('seller_id', '10', '1 day');
create trigger abuse_limit before insert on public.friendships
  for each row execute function public.abuse_limit('requester_id', '30', '1 day');
create trigger abuse_limit before insert on public.teams
  for each row execute function public.abuse_limit('owner_id', '3', '1 day');
create trigger abuse_limit before insert on public.content_reports
  for each row execute function public.abuse_limit('reporter_id', '20', '1 day');
create trigger abuse_limit before insert on public.messages
  for each row execute function public.abuse_limit('author_id', '5', '5 seconds');
