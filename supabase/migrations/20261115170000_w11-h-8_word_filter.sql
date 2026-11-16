-- L20: server-side word filter (SAFE-4).
--
-- The word check lived only in the client's WordList (SafetyKit); a modified
-- client could store blocked words on any surface. text_is_clean mirrors
-- WordList exactly — same blocked words, same letter-run matching, same
-- kill-yourself squash — and clean_text_guard rejects the write with
-- check_violation, the same failure mode the client has (the write is refused,
-- never redacted). One guard, attached to every table that stores
-- user-entered text; trigger arguments name the columns to check. Meets,
-- reports, and help requests are written by the gateway as service role;
-- triggers fire for those too.

create function public.text_is_clean(t text)
returns boolean
language sql stable
set search_path = public, extensions, pg_temp
as $$
  -- Fold like WordList: case and the common accented vowels, then split on
  -- anything that is not a letter. 'killyourself' is also caught squashed.
  select t is null
      or (translate(lower(t), 'áàâäãåéèêëíìîïóòôöõøúùûüçñ', 'aaaaaaeeeeiiiioooooouuuucn')
            !~ '(^|[^a-z])(nigger|nigga|faggot|fag|retard|kike|spic|chink|tranny|wetback|kys)([^a-z]|$)'
        and regexp_replace(
              translate(lower(t), 'áàâäãåéèêëíìîïóòôöõøúùûüçñ', 'aaaaaaeeeeiiiioooooouuuucn'),
              '[^a-z]', '', 'g') !~ 'killyourself');
$$;

create function public.clean_text_guard()
returns trigger
language plpgsql
set search_path = public, extensions, pg_temp
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  col   text;
begin
  -- Only new text is checked: an update that leaves a column alone (a
  -- moderation hide, a soft delete) is never blocked by what was already there.
  foreach col in array tg_argv loop
    if (v_new ->> col) is distinct from (v_old ->> col)
       and not public.text_is_clean(v_new ->> col) then
      raise exception 'blocked language' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

create trigger clean_text_guard before insert or update on public.profiles
  for each row execute function public.clean_text_guard('handle', 'display_name', 'bio');
create trigger clean_text_guard before insert or update on public.cars
  for each row execute function public.clean_text_guard('make', 'model', 'trim', 'nickname');
create trigger clean_text_guard before insert or update on public.teams
  for each row execute function public.clean_text_guard('name', 'tag', 'about');
create trigger clean_text_guard before insert or update on public.team_roles
  for each row execute function public.clean_text_guard('name');
create trigger clean_text_guard before insert or update on public.channels
  for each row execute function public.clean_text_guard('name');
create trigger clean_text_guard before insert or update on public.meets
  for each row execute function public.clean_text_guard('title', 'place_name', 'details', 'dest_name');
create trigger clean_text_guard before insert or update on public.roads
  for each row execute function public.clean_text_guard('name');
create trigger clean_text_guard before insert or update on public.road_loops
  for each row execute function public.clean_text_guard('name');
create trigger clean_text_guard before insert or update on public.spots
  for each row execute function public.clean_text_guard('make', 'model', 'city');
create trigger clean_text_guard before insert or update on public.venue_notes
  for each row execute function public.clean_text_guard('note');
create trigger clean_text_guard before insert or update on public.reports
  for each row execute function public.clean_text_guard('note');
create trigger clean_text_guard before insert or update on public.content_reports
  for each row execute function public.clean_text_guard('note');
create trigger clean_text_guard before insert or update on public.help_requests
  for each row execute function public.clean_text_guard('note');
create trigger clean_text_guard before insert or update on public.posts
  for each row execute function public.clean_text_guard('caption');
create trigger clean_text_guard before insert or update on public.post_comments
  for each row execute function public.clean_text_guard('body');
create trigger clean_text_guard before insert or update on public.messages
  for each row execute function public.clean_text_guard('body');
create trigger clean_text_guard before insert or update on public.listings
  for each row execute function public.clean_text_guard('title', 'description');
