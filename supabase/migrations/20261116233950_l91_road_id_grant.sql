-- L91 (audit finding): L74 added posts.road_id but the W11-H column-grant pass
-- only grants insert on a fixed column list; without this, a post carrying a
-- road gets 42501. Same shape as the other post columns in w11-h_database.

grant insert (road_id) on public.posts to authenticated;
