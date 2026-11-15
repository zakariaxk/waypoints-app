-- W11-H-6: close the block gaps the hardening pass found (SAFE-2).
--
-- spots_read, teams_read, and venue_notes_read applied the W7-1 moderation
-- rules (hidden_at / suspended via content_visible) but ignored blocks, so a
-- blocked user's spots, teams, and venue notes stayed visible to the blocker
-- (and vice versa). Each policy keeps its existing hidden/suspended semantics
-- and adds is_blocked_pair against the content owner. For teams the check sits
-- on the non-owner branch: a team is owned by one user, and the owner always
-- keeps sight of their own team.

drop policy spots_read on public.spots;
create policy spots_read on public.spots
  for select to authenticated
  using (
    public.content_visible(spotter_id, hidden_at)
    and not public.is_blocked_pair(spotter_id, auth.uid())
  );

drop policy venue_notes_read on public.venue_notes;
create policy venue_notes_read on public.venue_notes
  for select to authenticated
  using (
    public.content_visible(author_id, null)
    and not public.is_blocked_pair(author_id, auth.uid())
  );

drop policy teams_read on public.teams;
create policy teams_read on public.teams
  for select to authenticated
  using (
    owner_id = auth.uid()
    or (
      hidden_at is null
      and not public.is_blocked_pair(owner_id, auth.uid())
      and (is_public or public.is_team_member(id))
    )
  );
