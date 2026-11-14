-- W8-1E (PRD NTF-6, SAFE-1): help responses in Activity, and reports on help requests.
--
-- NTF-6: "On my way" (a help_responses insert, written only by the gateway) records one
-- Activity row for the requester, like the W7-2 triggers. The gateway still sends the push,
-- with Recorded set, so the row is not written twice. One row per responder per request (NTF-7).

set search_path = public, extensions;

create or replace function public.on_help_response_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requester uuid;
begin
  select h.requester_id into requester from public.help_requests h where h.id = new.request_id;
  if requester is not null then
    perform public.record_notification(requester, 'help_response', new.user_id,
      'waypoints://help/' || new.request_id,
      public.actor_name(new.user_id) || ' is on the way',
      'Tap to see your request.',
      'help_response:' || new.request_id || ':' || new.user_id);
  end if;
  return new;
end;
$$;
revoke all on function public.on_help_response_notify() from public, anon, authenticated;

create trigger help_responses_notify after insert on public.help_responses
  for each row execute function public.on_help_response_notify();

-- SAFE-1, SAFE-6: content_reports with target_kind 'help' point at a help request by id, so the
-- anonymous nearby form is reportable without the reporter learning who posted it. Three
-- distinct reporters within 7 days end the request (set_content_hidden has no help row, since
-- help_requests has no hidden_at; ending it removes it from every gateway read).
create or replace function public.content_reports_end_help()
returns trigger
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if new.target_kind = 'help' and (
    select count(distinct reporter_id)
    from public.content_reports
    where target_kind = 'help'
      and target_id = new.target_id
      and resolved_at is null
      and created_at > now() - interval '7 days'
  ) >= 3 then
    begin
      update public.help_requests set ended_at = coalesce(ended_at, now())
       where id = cast(btrim(new.target_id) as uuid);
    exception when invalid_text_representation then
      null;
    end;
  end if;
  return null;
end;
$$;
revoke all on function public.content_reports_end_help() from public, anon, authenticated;

create trigger content_reports_end_help
  after insert on public.content_reports
  for each row when (new.target_kind = 'help')
  execute function public.content_reports_end_help();
