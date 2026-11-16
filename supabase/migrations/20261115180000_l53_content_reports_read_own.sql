-- L53 (SAFE-3): a reporter can read back their own content_reports rows.
--
-- W0-C revoked select on content_reports with no read policy, so a reporter
-- could file a report but never see its status or result (resolved_at). The
-- reporter read path is what lets the client hide an item the reporter
-- reported (SAFE-3) and show "Thanks — we'll look into it" honestly. Other
-- users' rows stay service-role only.

grant select (id, reporter_id, target_kind, target_id, reason, note, resolved_at, created_at)
  on public.content_reports to authenticated;

create policy content_reports_read_own on public.content_reports
  for select to authenticated
  using (reporter_id = auth.uid());
