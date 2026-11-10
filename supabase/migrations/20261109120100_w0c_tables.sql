-- W0-C: every table in plan section 5.
-- Deleting a profile (or its auth.users row) cascades everywhere.
-- h3_* columns are written by the gateway (Postgres has no H3 extension here).

set search_path = public, extensions;

-- 5.1 People ------------------------------------------------------------

create table public.profiles (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  uid               bigint generated always as identity unique,
  handle            extensions.citext not null unique
                      check (handle::text ~ '^[a-z0-9_]{3,20}$'),
  display_name      text not null check (char_length(display_name) between 1 and 30),
  bio               text check (char_length(bio) <= 160),
  avatar_path       text,
  home_region       text check (char_length(home_region) <= 60),
  marker_icon       text not null default 'coupe' check (char_length(marker_icon) <= 40),
  marker_trail      text check (char_length(marker_trail) <= 40),
  primary_car_id    uuid,
  birth_year        int check (birth_year between 1900 and 2100),
  accepted_terms_at timestamptz,
  created_at        timestamptz not null default now()
);

create table public.friendships (
  requester_id uuid not null references public.profiles (user_id) on delete cascade,
  addressee_id uuid not null references public.profiles (user_id) on delete cascade,
  status       public.friendship_status not null default 'pending',
  created_at   timestamptz not null default now(),
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);
-- One row per pair regardless of direction.
create unique index friendships_pair_key
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_addressee_idx on public.friendships (addressee_id);

create table public.blocks (
  blocker_id uuid not null references public.profiles (user_id) on delete cascade,
  blocked_id uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked_idx on public.blocks (blocked_id);

create table public.privacy_settings (
  user_id             uuid primary key references public.profiles (user_id) on delete cascade,
  friends_level       public.share_level not null default 'precise',
  team_level          public.share_level not null default 'approx',
  nearby_level        public.share_level not null default 'hidden'
                        check (nearby_level <> 'precise'),
  ghost_until         timestamptz,
  notify_meets_nearby boolean not null default false,
  notify_radius_km    int not null default 15 check (notify_radius_km between 1 and 100),
  created_at          timestamptz not null default now()
);

create table public.user_presence_cell (
  user_id    uuid primary key references public.profiles (user_id) on delete cascade,
  h3_r7      bigint not null,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index user_presence_cell_h3_idx on public.user_presence_cell (h3_r7);

create table public.device_tokens (
  user_id     uuid not null references public.profiles (user_id) on delete cascade,
  apns_token  text not null check (char_length(apns_token) between 1 and 200),
  environment public.device_environment not null default 'production',
  created_at  timestamptz not null default now(),
  primary key (user_id, apns_token)
);

-- 5.2 Garage ------------------------------------------------------------

create table public.cars (
  id                 uuid primary key default gen_random_uuid(),
  owner_id           uuid not null references public.profiles (user_id) on delete cascade,
  catalog_variant_id bigint,
  year               int not null check (year between 1900 and 2100),
  make               text not null check (char_length(make) between 1 and 40),
  model              text not null check (char_length(model) between 1 and 60),
  trim               text check (char_length(trim) <= 60),
  nickname           text check (char_length(nickname) <= 30),
  color_family       text check (char_length(color_family) <= 20),
  color_hex          text check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  paint_name         text check (char_length(paint_name) <= 60),
  clearance          public.car_clearance not null default 'stock',
  spec_overrides     jsonb not null default '{}' check (jsonb_typeof(spec_overrides) = 'object'),
  mods               jsonb not null default '[]' check (jsonb_typeof(mods) = 'array'),
  sort               int not null default 0,
  created_at         timestamptz not null default now()
);
create index cars_owner_idx on public.cars (owner_id, sort);

alter table public.profiles
  add constraint profiles_primary_car_fkey
  foreign key (primary_car_id) references public.cars (id) on delete set null;

create table public.car_photos (
  id         uuid primary key default gen_random_uuid(),
  car_id     uuid not null references public.cars (id) on delete cascade,
  path       text not null,
  width      int check (width > 0),
  height     int check (height > 0),
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create index car_photos_car_idx on public.car_photos (car_id, sort);

create table public.build_entries (
  id          uuid primary key default gen_random_uuid(),
  car_id      uuid not null references public.cars (id) on delete cascade,
  happened_on date not null default current_date,
  title       text not null check (char_length(title) between 1 and 60),
  body        text check (char_length(body) <= 500),
  photo_path  text,
  mod_id      text,
  created_at  timestamptz not null default now()
);
create index build_entries_car_idx on public.build_entries (car_id, happened_on desc);

-- 5.4 Teams (before meets, which reference them) --------------------------

create table public.teams (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (user_id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  tag         text not null unique check (tag ~ '^[A-Z]{2,5}$'),
  about       text check (char_length(about) <= 300),
  icon_path   text,
  is_public   boolean not null default false,
  invite_code text not null unique
                default substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)
                check (invite_code ~ '^[A-Za-z0-9]{6,32}$'),
  created_at  timestamptz not null default now()
);

create table public.team_roles (
  id          uuid primary key default gen_random_uuid(),
  team_id     uuid not null references public.teams (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 30),
  color_hex   text check (color_hex ~ '^#[0-9A-Fa-f]{6}$'),
  rank        int not null default 0,
  -- bitset: manage_team 1, manage_channels 2, manage_roles 4, kick 8,
  -- delete_messages 16, host_meets 32
  permissions int not null default 0 check (permissions between 0 and 63),
  created_at  timestamptz not null default now(),
  unique (team_id, id),
  unique (team_id, name)
);

create table public.team_members (
  team_id    uuid not null references public.teams (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  role_id    uuid,
  joined_at  timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (team_id, user_id),
  -- A member's role must belong to the same team.
  foreign key (team_id, role_id) references public.team_roles (team_id, id)
    on delete set null (role_id)
);
create index team_members_user_idx on public.team_members (user_id);

create table public.channels (
  id         uuid primary key default gen_random_uuid(),
  team_id    uuid not null references public.teams (id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 30),
  kind       public.channel_kind not null default 'text',
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  unique (team_id, name),
  -- Text channels are lowercase-hyphen slugs; voice channel names are free text
  -- (the default voice channel is "Garage").
  check (kind = 'voice' or name ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

-- 5.3 Map content -------------------------------------------------------

create table public.reports (
  id            uuid primary key default gen_random_uuid(),
  author_id     uuid not null references public.profiles (user_id) on delete cascade,
  kind          public.report_kind not null,
  geom          geography(Point, 4326) not null,
  h3_r7         bigint,
  note          text check (char_length(note) <= 120),
  confirmations int not null default 1 check (confirmations >= 0),
  expires_at    timestamptz,
  permanent     boolean not null default false,
  created_at    timestamptz not null default now(),
  check (permanent or expires_at is not null)
);
create index reports_geom_idx on public.reports using gist (geom);
create index reports_h3_idx on public.reports (h3_r7);
create index reports_expires_idx on public.reports (expires_at) where not permanent;

create table public.report_votes (
  report_id   uuid not null references public.reports (id) on delete cascade,
  user_id     uuid not null references public.profiles (user_id) on delete cascade,
  still_there boolean not null,
  created_at  timestamptz not null default now(),
  primary key (report_id, user_id)
);

create table public.meets (
  id           uuid primary key default gen_random_uuid(),
  host_id      uuid not null references public.profiles (user_id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 50),
  kind         public.meet_kind not null default 'meet',
  geom         geography(Point, 4326) not null,
  h3_r7        bigint,
  place_name   text check (char_length(place_name) <= 80),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  details      text check (char_length(details) <= 500),
  visibility   public.meet_visibility not null default 'public',
  team_id      uuid references public.teams (id) on delete cascade,
  cancelled_at timestamptz,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at),
  check ((visibility = 'team') = (team_id is not null))
);
create index meets_geom_idx on public.meets using gist (geom);
create index meets_ends_idx on public.meets (ends_at);
create index meets_h3_idx on public.meets (h3_r7);

create table public.meet_rsvps (
  meet_id    uuid not null references public.meets (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  status     public.rsvp_status not null default 'going',
  car_id     uuid references public.cars (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (meet_id, user_id)
);
create index meet_rsvps_user_idx on public.meet_rsvps (user_id);

create table public.venue_notes (
  id         uuid primary key default gen_random_uuid(),
  geom       geography(Point, 4326) not null,
  h3_r9      bigint,
  author_id  uuid not null references public.profiles (user_id) on delete cascade,
  entrance   public.entrance_grade,
  lot_size   public.lot_size,
  lit        boolean,
  note       text check (char_length(note) <= 120),
  created_at timestamptz not null default now()
);
create index venue_notes_geom_idx on public.venue_notes using gist (geom);

create table public.roads (
  id         uuid primary key default gen_random_uuid(),
  author_id  uuid not null references public.profiles (user_id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 50),
  path       geography(LineString, 4326) not null,
  length_m   int check (length_m >= 0),
  h3_r7      bigint,
  created_at timestamptz not null default now()
);
create index roads_path_idx on public.roads using gist (path);

create table public.road_ratings (
  road_id    uuid not null references public.roads (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  surface    int not null check (surface between 1 and 5),
  scenery    int not null check (scenery between 1 and 5),
  traffic    int not null check (traffic between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (road_id, user_id)
);

create table public.spots (
  id               uuid primary key default gen_random_uuid(),
  spotter_id       uuid not null references public.profiles (user_id) on delete cascade,
  catalog_model_id bigint,
  year             int check (year between 1900 and 2100),
  make             text not null check (char_length(make) between 1 and 40),
  model            text not null check (char_length(model) between 1 and 60),
  photo_path       text,
  city             text check (char_length(city) <= 60),
  h3_r5            bigint,
  created_at       timestamptz not null default now()
);
create index spots_spotter_idx on public.spots (spotter_id);

-- 5.5 Market (before threads, which reference listings) --------------------

create table public.listings (
  id             uuid primary key default gen_random_uuid(),
  seller_id      uuid not null references public.profiles (user_id) on delete cascade,
  kind           public.listing_kind not null,
  title          text not null check (char_length(title) between 1 and 70),
  price_cents    int not null check (price_cents >= 0),
  condition      public.listing_condition not null,
  description    text check (char_length(description) <= 1500),
  fits_make      text check (char_length(fits_make) <= 40),
  fits_model     text check (char_length(fits_model) <= 60),
  fits_year_from int check (fits_year_from between 1900 and 2100),
  fits_year_to   int check (fits_year_to between 1900 and 2100),
  car_id         uuid references public.cars (id) on delete set null,
  region         text check (char_length(region) <= 60),
  h3_r5          bigint,
  status         public.listing_status not null default 'active',
  created_at     timestamptz not null default now(),
  check (fits_year_from is null or fits_year_to is null or fits_year_from <= fits_year_to)
);
create index listings_status_idx on public.listings (status, created_at desc);
create index listings_seller_idx on public.listings (seller_id);

create table public.listing_photos (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  path       text not null,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);
create index listing_photos_listing_idx on public.listing_photos (listing_id, sort);

create table public.listing_saves (
  listing_id uuid not null references public.listings (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (listing_id, user_id)
);

-- 5.4 Messaging ---------------------------------------------------------

create table public.threads (
  id         uuid primary key default gen_random_uuid(),
  kind       public.thread_kind not null,
  listing_id uuid references public.listings (id) on delete cascade,
  a_id       uuid not null references public.profiles (user_id) on delete cascade,
  b_id       uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  check (a_id <> b_id),
  check ((kind = 'listing') = (listing_id is not null))
);
create unique index threads_pair_key on public.threads (
  kind,
  coalesce(listing_id, '00000000-0000-0000-0000-000000000000'::uuid),
  least(a_id, b_id),
  greatest(a_id, b_id)
);
create index threads_a_idx on public.threads (a_id);
create index threads_b_idx on public.threads (b_id);

create table public.messages (
  id              bigint generated always as identity primary key,
  channel_id      uuid references public.channels (id) on delete cascade,
  thread_id       uuid references public.threads (id) on delete cascade,
  author_id       uuid not null references public.profiles (user_id) on delete cascade,
  body            text not null default '' check (char_length(body) <= 2000),
  attachment_path text,
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  check (num_nonnulls(channel_id, thread_id) = 1),
  check (deleted_at is not null or char_length(body) > 0 or attachment_path is not null)
);
create index messages_channel_idx on public.messages (channel_id, id desc) where channel_id is not null;
create index messages_thread_idx on public.messages (thread_id, id desc) where thread_id is not null;

create table public.read_markers (
  user_id              uuid not null references public.profiles (user_id) on delete cascade,
  channel_id           uuid references public.channels (id) on delete cascade,
  thread_id            uuid references public.threads (id) on delete cascade,
  last_read_message_id bigint not null,
  created_at           timestamptz not null default now(),
  check (num_nonnulls(channel_id, thread_id) = 1),
  constraint read_markers_key unique nulls not distinct (user_id, channel_id, thread_id)
);

-- 5.5 Feed, Showdown, Progress, Safety --------------------------------------

create table public.posts (
  id            uuid primary key default gen_random_uuid(),
  author_id     uuid not null references public.profiles (user_id) on delete cascade,
  car_id        uuid references public.cars (id) on delete set null,
  video_path    text not null,
  poster_path   text,
  caption       text check (char_length(caption) <= 150),
  duration_ms   int check (duration_ms between 1 and 31000),
  like_count    int not null default 0 check (like_count >= 0),
  comment_count int not null default 0 check (comment_count >= 0),
  created_at    timestamptz not null default now()
);
create index posts_created_idx on public.posts (created_at desc);
create index posts_author_idx on public.posts (author_id, created_at desc);

create table public.post_likes (
  post_id    uuid not null references public.posts (id) on delete cascade,
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index post_likes_user_idx on public.post_likes (user_id);

create table public.post_comments (
  id         uuid primary key default gen_random_uuid(),
  post_id    uuid not null references public.posts (id) on delete cascade,
  author_id  uuid not null references public.profiles (user_id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index post_comments_post_idx on public.post_comments (post_id, created_at);

create table public.follows (
  follower_id uuid not null references public.profiles (user_id) on delete cascade,
  followee_id uuid not null references public.profiles (user_id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (follower_id, followee_id),
  check (follower_id <> followee_id)
);
create index follows_followee_idx on public.follows (followee_id);

create table public.showdown_entries (
  car_id     uuid primary key references public.cars (id) on delete cascade,
  rating     int not null default 1200,
  wins       int not null default 0 check (wins >= 0),
  losses     int not null default 0 check (losses >= 0),
  class      public.showdown_class not null default 'street',
  created_at timestamptz not null default now()
);
create index showdown_entries_rating_idx on public.showdown_entries (class, rating desc);

create table public.showdown_votes (
  voter_id      uuid not null references public.profiles (user_id) on delete cascade,
  winner_car_id uuid not null references public.cars (id) on delete cascade,
  loser_car_id  uuid not null references public.cars (id) on delete cascade,
  car_lo        uuid generated always as (least(winner_car_id, loser_car_id)) stored,
  car_hi        uuid generated always as (greatest(winner_car_id, loser_car_id)) stored,
  created_at    timestamptz not null default now(),
  primary key (voter_id, car_lo, car_hi),
  check (winner_car_id <> loser_car_id)
);
create index showdown_votes_created_idx on public.showdown_votes (created_at);

create table public.achievements (
  user_id    uuid not null references public.profiles (user_id) on delete cascade,
  key        text not null check (key ~ '^[a-z0-9_.]{1,60}$'),
  earned_at  timestamptz not null default now(),
  created_at timestamptz not null default now(),
  primary key (user_id, key)
);

create table public.content_reports (
  id          uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (user_id) on delete cascade,
  target_kind text not null check (char_length(target_kind) between 1 and 30),
  target_id   text not null check (char_length(target_id) between 1 and 100),
  reason      public.content_reason not null,
  note        text check (char_length(note) <= 500),
  resolved_at timestamptz,
  created_at  timestamptz not null default now()
);
create index content_reports_open_idx on public.content_reports (created_at) where resolved_at is null;

create table public.race_results (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (user_id) on delete cascade,
  car_id       uuid not null references public.cars (id) on delete cascade,
  mods         jsonb not null default '[]' check (jsonb_typeof(mods) = 'array'),
  reaction_ms  int,
  et_ms        int not null check (et_ms > 0),
  trap_mph_x10 int check (trap_mph_x10 >= 0),
  sixty_ft_ms  int check (sixty_ft_ms > 0),
  input_log    bytea check (octet_length(input_log) <= 4096),
  created_at   timestamptz not null default now()
);
create index race_results_et_idx on public.race_results (et_ms);
create index race_results_user_idx on public.race_results (user_id);
