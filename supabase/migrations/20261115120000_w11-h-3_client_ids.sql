-- W11-H follow-up: the column-level INSERT grants in 20261115080000 kept clients from
-- writing server-owned columns, but they also withheld `id`. The app never sends ids
-- (defaults generate them), yet checks.sql fixtures do, and a client-chosen uuid
-- primary key is harmless: the unique index and RLS still apply. Restore `id` on the
-- three tables whose fixtures name their rows.

grant insert (id) on public.threads to authenticated;
grant insert (id) on public.posts to authenticated;
grant insert (id) on public.post_comments to authenticated;
