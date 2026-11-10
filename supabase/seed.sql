-- W0-C: local seed data. Philadelphia and South Jersey.
-- 12 drivers, 20 cars, 6 meets, 30 reports, 3 teams, plus friendships,
-- RSVPs, channel messages, roads, venue notes, and listings.
-- Sign in locally with any seeded email and the one-time code from Inbucket.
-- Times are relative to now() so meets stay upcoming and reports stay live.
-- h3_* columns are left null; the gateway fills them on write.

set search_path = public, extensions;

-- Drivers -----------------------------------------------------------------
-- Inserting into auth.users fires handle_new_user(), which creates the
-- profile (handle and display name from metadata) and privacy row.

with drivers (n, email, handle, display_name) as (
  values
    (1,  'marcus.reyes@waypoints.test',    'marcus_s2k',   'Marcus Reyes'),
    (2,  'dana.whitfield@waypoints.test',  'dana_gti',     'Dana Whitfield'),
    (3,  'priya.natarajan@waypoints.test', 'priya_wrx',    'Priya Natarajan'),
    (4,  'tom.kowalski@waypoints.test',    'tkowalski',    'Tom Kowalski'),
    (5,  'jaylen.brooks@waypoints.test',   'jaylen_e46',   'Jaylen Brooks'),
    (6,  'sofia.moretti@waypoints.test',   'sofia_mk4',    'Sofia Moretti'),
    (7,  'ray.delgado@waypoints.test',     'ray_foxbody',  'Ray Delgado'),
    (8,  'kenji.watanabe@waypoints.test',  'kenji_ae86',   'Kenji Watanabe'),
    (9,  'alexis.grant@waypoints.test',    'alexis_fl5',   'Alexis Grant'),
    (10, 'omar.haddad@waypoints.test',     'omar_350z',    'Omar Haddad'),
    (11, 'bree.lawson@waypoints.test',     'bree_a90',     'Bree Lawson'),
    (12, 'nick.ferraro@waypoints.test',    'nick_evo',     'Nick Ferraro')
)
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
select
  '00000000-0000-0000-0000-000000000000',
  format('a0000000-0000-4000-8000-%s', lpad(n::text, 12, '0'))::uuid,
  'authenticated', 'authenticated', email, '', now() - interval '60 days',
  '{"provider": "email", "providers": ["email"]}',
  jsonb_build_object('handle', handle, 'display_name', display_name),
  now() - interval '60 days' + n * interval '2 days', now(),
  '', '', '', ''
from drivers;

insert into auth.identities (
  id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select gen_random_uuid(), u.id::text, u.id,
       jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
       'email', now(), u.created_at, now()
from auth.users u
where u.email like '%@waypoints.test';

update public.profiles p
set bio = d.bio,
    home_region = d.region,
    marker_icon = d.marker,
    birth_year = d.birth_year,
    accepted_terms_at = now() - interval '59 days'
from (values
  (1,  'AP1 owner since 2014. Sunday mornings on Route 206.',            'Cherry Hill',     'roadster', 1991),
  (2,  'Daily-driven GTI and a Cooper S that is always in the shop.',    'Collingswood',    'hatch',    1996),
  (3,  'Two Subarus, zero regrets. I run the Pine Barrens Drivers.',     'Marlton',         'sedan',    1993),
  (4,  'NA Miata, hand-me-down tools, and a lot of patience.',          'Fishtown',        'roadster', 1988),
  (5,  'S54 enjoyer. E30 project that will be done next spring.',        'Voorhees',        'coupe',    1990),
  (6,  'MK4 1.8T on coilovers. Ask me about coil packs.',                'Haddonfield',     'sedan',    1998),
  (7,  'Fox body since high school. Focus ST for the commute.',          'Pennsauken',      'muscle',   1979),
  (8,  'Hachiroku and its grandkid. Trail braking is a lifestyle.',       'Moorestown',      'coupe',    1985),
  (9,  'FL5 in Championship White. Track days at NJMP when I can.',      'Mount Laurel',    'hatch',    1997),
  (10, 'Z33 track build and a KA24 240SX that will not die.',            'Deptford',        'coupe',    1994),
  (11, 'A90 Supra, Renaissance Red. Mostly photos, occasionally speed.',  'Medford',         'coupe',    1992),
  (12, 'Evo X and a Focus RS. AWD everything.',                          'South Philly',    'sedan',    1989)
) as d(n, bio, region, marker, birth_year)
where p.user_id = format('a0000000-0000-4000-8000-%s', lpad(d.n::text, 12, '0'))::uuid;

-- A few non-default privacy choices.
update public.privacy_settings set nearby_level = 'approx', notify_meets_nearby = true
where user_id in ('a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003',
                  'a0000000-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000012');
update public.privacy_settings set team_level = 'precise', notify_meets_nearby = true, notify_radius_km = 30
where user_id = 'a0000000-0000-4000-8000-000000000003';

-- Cars (20) ---------------------------------------------------------------

insert into public.cars (id, owner_id, year, make, model, trim, nickname, color_family, color_hex, paint_name, clearance, spec_overrides, sort)
select format('c0000000-0000-4000-8000-%s', lpad(c.n::text, 12, '0'))::uuid,
       format('a0000000-0000-4000-8000-%s', lpad(c.owner::text, 12, '0'))::uuid,
       c.year, c.make, c.model, c.trim, c.nickname, c.family, c.hex, c.paint,
       c.clearance::public.car_clearance, c.spec::jsonb, c.sort
from (values
  (1,  1,  2006, 'Honda',      'S2000',              'Base',          null,         'silver', '#C7C9CB', 'Silverstone Metallic',  'lowered', '{}',                          0),
  (2,  1,  1998, 'Honda',      'Civic',              'EX Coupe',      'The EJ8',    'red',    '#B0172B', 'Milano Red',            'slammed', '{"hp": 160}',                 1),
  (3,  2,  2019, 'Volkswagen', 'Golf GTI',           'Autobahn',      null,         'grey',   '#4A4D50', 'Indium Grey Metallic',  'lowered', '{"hp": 265, "torque": 300}',  0),
  (4,  2,  2011, 'MINI',       'Cooper S',           'Hardtop',       'Bean',       'green',  '#1F4D3A', 'British Racing Green',  'stock',   '{}',                          1),
  (5,  3,  2022, 'Subaru',     'WRX',                'Premium',       null,         'blue',   '#1B4F9C', 'WR Blue Pearl',         'stock',   '{}',                          0),
  (6,  3,  2004, 'Subaru',     'Impreza WRX STI',    'Base',          'Blobeye',    'blue',   '#1E3F8A', 'WR Blue Pearl',         'lowered', '{"hp": 330}',                 1),
  (7,  4,  1999, 'Mazda',      'MX-5 Miata',         'Base',          null,         'red',    '#B5121B', 'Classic Red',           'lowered', '{}',                          0),
  (8,  5,  2003, 'BMW',        'M3',                 'Coupe',         null,         'blue',   '#2A3F6B', 'Laguna Seca Blue',      'stock',   '{}',                          0),
  (9,  5,  1991, 'BMW',        '318is',              'Coupe',         'Project E30','white',  '#ECECE6', 'Alpine White',          'lowered', '{}',                          1),
  (10, 6,  2001, 'Volkswagen', 'Jetta',              'GLS 1.8T',      null,         'black',  '#141414', 'Black Magic Pearl',     'slammed', '{"hp": 210}',                 0),
  (11, 7,  1989, 'Ford',       'Mustang',            'GT',            'Fox',        'white',  '#F1F1EC', 'Oxford White',          'lowered', '{"hp": 265, "gears": 5}',     0),
  (12, 7,  2014, 'Ford',       'Focus ST',           'Base',          null,         'orange', '#E36F1E', 'Tangerine Scream',      'stock',   '{}',                          1),
  (13, 8,  2017, 'Toyota',     '86',                 'Base',          null,         'red',    '#9C1C1F', 'Pure Red',              'lowered', '{}',                          0),
  (14, 8,  1986, 'Toyota',     'Corolla',            'GT-S',          'Hachiroku',  'black',  '#1A1A1A', 'Black and Silver',      'lowered', '{}',                          1),
  (15, 9,  2023, 'Honda',      'Civic Type R',       'Base',          null,         'white',  '#F4F4F2', 'Championship White',    'stock',   '{}',                          0),
  (16, 10, 2005, 'Nissan',     '350Z',               'Track',         null,         'silver', '#9EA1A3', 'Silverstone',           'lowered', '{"hp": 300}',                 0),
  (17, 10, 1993, 'Nissan',     '240SX',              'SE Fastback',   null,         'black',  '#16181A', 'Super Black',           'slammed', '{}',                          1),
  (18, 11, 2020, 'Toyota',     'GR Supra',           '3.0 Premium',   null,         'red',    '#B3121E', 'Renaissance Red 2.0',   'stock',   '{}',                          0),
  (19, 12, 2008, 'Mitsubishi', 'Lancer Evolution',   'GSR',           null,         'grey',   '#5B5F63', 'Graphite Gray',         'lowered', '{"hp": 340, "torque": 330}',  0),
  (20, 12, 2016, 'Ford',       'Focus RS',           'Base',          null,         'blue',   '#2B5FA8', 'Nitrous Blue',          'stock',   '{}',                          1)
) as c(n, owner, year, make, model, trim, nickname, family, hex, paint, clearance, spec, sort);

update public.profiles p
set primary_car_id = c.id
from public.cars c
where c.owner_id = p.user_id and c.sort = 0;

insert into public.car_photos (car_id, path, width, height, sort)
select c.id, format('%s/%s/1.jpg', c.owner_id, c.id), 2048, 1536, 0
from public.cars c;

insert into public.build_entries (car_id, happened_on, title, body)
values
  ('c0000000-0000-4000-8000-000000000001', current_date - 400, 'Bought it', 'One owner, 71k miles, a little curb rash on the front lip.'),
  ('c0000000-0000-4000-8000-000000000001', current_date - 120, 'Coilovers and alignment', 'Mild drop, stiffer than stock but fine on 295.'),
  ('c0000000-0000-4000-8000-000000000006', current_date - 200, 'Timing belt and water pump', 'Done at 105k. EJ257 sounds happier.'),
  ('c0000000-0000-4000-8000-000000000011', current_date - 90,  'Cylinder heads', 'Swapped to aluminum heads and a new cam.'),
  ('c0000000-0000-4000-8000-000000000014', current_date - 30,  'Fresh 4A-GE rebuild', 'Break-in miles on back roads only.');

-- Social graph ------------------------------------------------------------

insert into public.friendships (requester_id, addressee_id, status)
select format('a0000000-0000-4000-8000-%s', lpad(f.a::text, 12, '0'))::uuid,
       format('a0000000-0000-4000-8000-%s', lpad(f.b::text, 12, '0'))::uuid,
       f.s::public.friendship_status
from (values
  (1, 3, 'accepted'), (1, 5, 'accepted'), (1, 9, 'accepted'), (2, 6, 'accepted'),
  (3, 8, 'accepted'), (3, 11, 'accepted'), (4, 7, 'accepted'), (4, 12, 'accepted'),
  (5, 6, 'accepted'), (9, 10, 'accepted'), (10, 12, 'accepted'), (8, 12, 'accepted'),
  (2, 1, 'pending'), (7, 11, 'pending')
) as f(a, b, s);

insert into public.follows (follower_id, followee_id)
select format('a0000000-0000-4000-8000-%s', lpad(f.a::text, 12, '0'))::uuid,
       format('a0000000-0000-4000-8000-%s', lpad(f.b::text, 12, '0'))::uuid
from (values (2, 11), (4, 1), (6, 3), (7, 9), (8, 11), (10, 1), (12, 9), (5, 11)) as f(a, b);

-- Teams (3) ---------------------------------------------------------------
-- teams_bootstrap() adds Owner and Member roles, the owner's membership,
-- and the general and Garage channels.

insert into public.teams (id, owner_id, name, tag, about, is_public, invite_code)
values
  ('e0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003',
   'Pine Barrens Drivers', 'PBD',
   'Back roads east of the 206 corridor. Sunday drives at a sane pace, no street racing.',
   true, 'pinebarrens'),
  ('e0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000005',
   'Philly Euro Society', 'PES',
   'German and Italian metal from both sides of the river. Invite only, ask in a meet.',
   false, 'europhl2026'),
  ('e0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000001',
   'South Jersey Import Alliance', 'SJIA',
   'Hondas, Nissans, Toyotas, Subarus. Monthly meet at the Cherry Hill lot.',
   true, 'sjimports');

insert into public.team_roles (team_id, name, color_hex, rank, permissions)
values
  ('e0000000-0000-4000-8000-000000000001', 'Road Captain', '#D9A441', 50, 2 | 16 | 32),
  ('e0000000-0000-4000-8000-000000000003', 'Moderator',    '#6FA287', 50, 8 | 16);

insert into public.team_members (team_id, user_id)
select format('e0000000-0000-4000-8000-%s', lpad(m.t::text, 12, '0'))::uuid,
       format('a0000000-0000-4000-8000-%s', lpad(m.u::text, 12, '0'))::uuid
from (values
  (1, 1), (1, 8), (1, 11), (1, 4), (1, 9),
  (2, 2), (2, 6), (2, 12), (2, 4),
  (3, 9), (3, 10), (3, 8), (3, 3), (3, 7)
) as m(t, u);

update public.team_members tm
set role_id = r.id
from public.team_roles r
where r.team_id = tm.team_id
  and ((tm.team_id = 'e0000000-0000-4000-8000-000000000001' and tm.user_id = 'a0000000-0000-4000-8000-000000000008' and r.name = 'Road Captain')
    or (tm.team_id = 'e0000000-0000-4000-8000-000000000003' and tm.user_id = 'a0000000-0000-4000-8000-000000000010' and r.name = 'Moderator'));

insert into public.channels (team_id, name, kind, sort)
values
  ('e0000000-0000-4000-8000-000000000001', 'route-planning', 'text', 2),
  ('e0000000-0000-4000-8000-000000000002', 'parts-and-tools', 'text', 2),
  ('e0000000-0000-4000-8000-000000000003', 'meet-photos', 'text', 2);

insert into public.messages (channel_id, author_id, body, created_at)
select ch.id, format('a0000000-0000-4000-8000-%s', lpad(m.u::text, 12, '0'))::uuid, m.body,
       now() - m.ago * interval '1 minute'
from (values
  (1, 'general',        3,  'Sunday run is on. Meeting at the Wawa on Route 70 in Medford, wheels up at 8:30.', 600),
  (1, 'general',        8,  'In. Bringing the 86, the AE86 is still breaking in.',                             590),
  (1, 'general',        11, 'Can we stop at the Pine Barrens Tribune overlook for photos?',                     580),
  (1, 'route-planning', 3,  'Route 532 to 563 is freshly paved past Chatsworth. Watch for sand on the shoulders.', 300),
  (2, 'general',        5,  'S54 rod bearings done. Anyone have a torque wrench that goes to 100 Nm I can borrow?', 900),
  (2, 'general',        6,  'I have one. Bring coffee to Haddonfield.',                                         880),
  (2, 'parts-and-tools',12, 'Selling a set of Bilstein B6 for an E46, 20k miles.',                              200),
  (3, 'general',        1,  'Monthly meet moved to the north lot at Cherry Hill Mall. Security said yes.',       1200),
  (3, 'general',        9,  'FL5 will be there, freshly detailed.',                                             1150),
  (3, 'general',        10, 'Reminder: no burnouts leaving the lot. We lose the spot if anyone does.',          1100),
  (3, 'meet-photos',    7,  'Last month''s photos are up in the shared album.',                                 400)
) as m(t, ch_name, u, body, ago)
join public.channels ch
  on ch.team_id = format('e0000000-0000-4000-8000-%s', lpad(m.t::text, 12, '0'))::uuid
 and ch.name = m.ch_name
order by m.ago desc;

insert into public.threads (id, kind, a_id, b_id)
values ('f0000000-0000-4000-8000-000000000001', 'dm',
        'a0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000005');

insert into public.messages (thread_id, author_id, body, created_at)
values
  ('f0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001', 'You still running the 295 to Route 70 loop Saturday?', now() - interval '3 hours'),
  ('f0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000005', 'Yes, leaving Voorhees at 7. I will drop a convoy code.', now() - interval '2 hours 50 minutes');

-- Meets (6) ---------------------------------------------------------------

insert into public.meets (id, host_id, title, kind, geom, place_name, starts_at, ends_at, details, visibility, team_id)
values
  ('d0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000001',
   'Sunday cars and coffee', 'meet',
   st_setsrid(st_makepoint(-75.0247, 39.9419), 4326)::geography, 'Cherry Hill Mall, north lot',
   date_trunc('day', now()) + interval '3 days 12 hours', date_trunc('day', now()) + interval '3 days 14 hours',
   'Park nose out along the light poles. Coffee from the Wawa across Haddonfield Road.', 'public', null),
  ('d0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000003',
   'Route 206 Pine Barrens cruise', 'cruise',
   st_setsrid(st_makepoint(-74.8236, 39.9010), 4326)::geography, 'Wawa, Route 70, Medford',
   date_trunc('day', now()) + interval '6 days 12 hours 30 minutes', date_trunc('day', now()) + interval '6 days 16 hours',
   'About 70 miles through Chatsworth and Batsto. Fuel up before, there is nothing out there.', 'public', null),
  ('d0000000-0000-4000-8000-000000000003', 'a0000000-0000-4000-8000-000000000009',
   'Friday night at the Promenade', 'hangout',
   st_setsrid(st_makepoint(-74.9027, 39.8765), 4326)::geography, 'The Promenade at Sagemore, Marlton',
   date_trunc('day', now()) + interval '1 day 23 hours', date_trunc('day', now()) + interval '2 days 2 hours',
   'Back lot behind the movie theater. Low-key, leave quietly.', 'public', null),
  ('d0000000-0000-4000-8000-000000000004', 'a0000000-0000-4000-8000-000000000003',
   'PBD monthly', 'meet',
   st_setsrid(st_makepoint(-75.0716, 39.9136), 4326)::geography, 'Knight Park, Collingswood',
   date_trunc('day', now()) + interval '10 days 22 hours', date_trunc('day', now()) + interval '11 days',
   'Members only. Route planning for the fall leaf run.', 'team', 'e0000000-0000-4000-8000-000000000001'),
  ('d0000000-0000-4000-8000-000000000005', 'a0000000-0000-4000-8000-000000000004',
   'Night photos at Race Street Pier', 'show',
   st_setsrid(st_makepoint(-75.1398, 39.9531), 4326)::geography, 'Race Street Pier, Philadelphia',
   date_trunc('day', now()) + interval '4 days 1 hour', date_trunc('day', now()) + interval '4 days 3 hours',
   'Ben Franklin Bridge lit up behind the cars. Tripods welcome.', 'friends', null),
  ('d0000000-0000-4000-8000-000000000006', 'a0000000-0000-4000-8000-000000000012',
   'NJMP Thunderbolt open track', 'track_day',
   st_setsrid(st_makepoint(-75.0705, 39.3590), 4326)::geography, 'New Jersey Motorsports Park, Millville',
   date_trunc('day', now()) + interval '13 days 12 hours', date_trunc('day', now()) + interval '13 days 21 hours',
   'Novice group has instructors. Helmet SA2015 or newer, tech inspection at 7:30.', 'public', null);

insert into public.meet_rsvps (meet_id, user_id, status, car_id)
select format('d0000000-0000-4000-8000-%s', lpad(r.m::text, 12, '0'))::uuid,
       format('a0000000-0000-4000-8000-%s', lpad(r.u::text, 12, '0'))::uuid,
       r.s::public.rsvp_status,
       (select id from public.cars
         where owner_id = format('a0000000-0000-4000-8000-%s', lpad(r.u::text, 12, '0'))::uuid
         order by sort limit 1)
from (values
  (1, 1, 'going'), (1, 3, 'going'), (1, 9, 'going'), (1, 10, 'maybe'), (1, 7, 'going'),
  (2, 3, 'going'), (2, 8, 'going'), (2, 11, 'going'), (2, 1, 'maybe'),
  (3, 9, 'going'), (3, 2, 'maybe'), (3, 6, 'going'),
  (4, 3, 'going'), (4, 8, 'going'),
  (5, 4, 'going'), (5, 7, 'going'), (5, 12, 'maybe'),
  (6, 12, 'going'), (6, 9, 'going'), (6, 10, 'going')
) as r(m, u, s);

-- Reports (30) ------------------------------------------------------------

insert into public.reports (author_id, kind, geom, note, confirmations, created_at, expires_at)
select format('a0000000-0000-4000-8000-%s', lpad(r.u::text, 12, '0'))::uuid,
       r.kind::public.report_kind,
       st_setsrid(st_makepoint(r.lng, r.lat), 4326)::geography,
       r.note, r.conf,
       now() - r.ago * interval '1 minute',
       case when public.report_lifetime(r.kind::public.report_kind) is null then null
            else now() - r.ago * interval '1 minute' + public.report_lifetime(r.kind::public.report_kind)
       end
from (values
  (1,  'speed_bump',     39.9372, -75.0154, 'Three tall humps in the Kings Highway Wawa lot',   4,  20000),
  (2,  'speed_bump',     39.9178, -75.0705, 'Haddon Ave municipal lot, scrapes anything lowered', 6, 30000),
  (6,  'steep_entrance', 39.8973, -75.0335, 'Steep lip into the Haddonfield ShopRite lot. Angle it.', 5, 25000),
  (5,  'steep_entrance', 39.8510, -74.9594, 'Echelon Rd plaza entrance, come in from the side driveway', 3, 18000),
  (8,  'pothole',        39.9692, -74.9490, 'Deep one in the right lane on Main St eastbound',  2,  3000),
  (10, 'pothole',        39.8366, -75.1093, 'Route 41 southbound before the light',             3,  9000),
  (12, 'pothole',        39.9291, -75.1631, 'Broad St northbound at Snyder, rim-bender',        7,  1500),
  (4,  'rough_road',     39.9726, -75.1307, 'Frankford Ave cobbles and trolley tracks',          4,  40000),
  (3,  'rough_road',     39.7714, -74.6411, 'Route 532 patchwork past the fire tower',           2,  12000),
  (7,  'rough_road',     39.9842, -75.0476, 'River Rd broken shoulder through Riverton',         1,  6000),
  (9,  'police',         39.9231, -74.9585, 'Speed trap at the Route 73 median cut',             3,  12),
  (11, 'police',         39.8967, -74.8191, 'Parked behind the church on Route 70',              2,  25),
  (12, 'police',         39.9454, -75.1593, 'Checkpoint on Spring Garden near the art museum',   5,  30),
  (1,  'police',         39.9139, -75.0063, 'I-295 northbound shoulder near exit 34',            1,  8),
  (2,  'hazard',         39.9353, -75.0457, 'Mattress in the left lane on Route 70 westbound',   2,  40),
  (5,  'hazard',         39.8657, -75.0210, 'Gravel spill on Laurel Oak Rd after the bend',      1,  70),
  (8,  'hazard',         39.9812, -74.9071, 'Deer crossing near the Rancocas Creek bridge',       3,  90),
  (10, 'hazard',         39.8193, -75.1310, 'Oil slick on the ramp from 295 to Route 42',        4,  20),
  (3,  'closure',        39.9512, -75.1424, 'Market St closed for filming between 2nd and 4th',  6,  300),
  (6,  'closure',        39.9007, -75.0265, 'Kings Hwy bridge over the Cooper closed overnight', 2,  600),
  (11, 'closure',        39.8459, -74.6956, 'Route 206 detour at Atsion for paving',              3,  900),
  (4,  'fuel_e85',       39.9585, -75.0790, 'Sunoco on Route 130 has E85 at pump 7',              8,  50000),
  (7,  'fuel_e85',       39.8731, -74.9221, 'Marlton Pike Gulf, E85 posted by the air pump',      5,  60000),
  (12, 'fuel_e85',       39.9216, -75.1824, 'Grays Ferry Sunoco, E85 when it is not broken',      3,  45000),
  (9,  'speed_bump',     39.9480, -74.9715, 'Moorestown Mall back road, unmarked bump',           2,  22000),
  (1,  'pothole',        39.9421, -75.0275, 'Haddonfield Rd at the mall entrance light',         5,  4000),
  (3,  'hazard',         39.8890, -74.7820, 'Fallen branches on Tabernacle Rd after the storm',   2,  50),
  (5,  'police',         39.8392, -74.9785, 'Unmarked Charger on Route 561 at the Wawa',          2,  15),
  (8,  'steep_entrance', 39.9579, -74.9906, 'Route 38 diner lot drops off hard at the curb',      4,  35000),
  (2,  'closure',        39.9166, -75.0544, 'Cooper River Park drive closed for the regatta',     4,  200)
) as r(u, kind, lat, lng, note, conf, ago);

-- Roads, venue notes ------------------------------------------------------

insert into public.roads (id, author_id, name, path)
values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003',
   'Route 563 through Wharton State Forest',
   st_geogfromtext('SRID=4326;LINESTRING(-74.5874 39.8195, -74.5727 39.7660, -74.5643 39.7101, -74.5511 39.6623)')),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000008',
   'Rancocas Road, Mount Holly to Hainesport',
   st_geogfromtext('SRID=4326;LINESTRING(-74.7874 39.9926, -74.8102 39.9874, -74.8288 39.9781)'));

insert into public.road_ratings (road_id, user_id, surface, scenery, traffic)
values
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000003', 4, 5, 5),
  ('b0000000-0000-4000-8000-000000000001', 'a0000000-0000-4000-8000-000000000011', 3, 5, 4),
  ('b0000000-0000-4000-8000-000000000002', 'a0000000-0000-4000-8000-000000000008', 3, 3, 3);

insert into public.venue_notes (geom, author_id, entrance, lot_size, lit, note)
values
  (st_setsrid(st_makepoint(-75.0247, 39.9419), 4326)::geography, 'a0000000-0000-4000-8000-000000000001',
   'flat', 'large', true, 'Enter from Haddonfield Rd, the Route 38 side has a dip.'),
  (st_setsrid(st_makepoint(-74.9027, 39.8765), 4326)::geography, 'a0000000-0000-4000-8000-000000000009',
   'moderate', 'medium', true, 'Back lot is fine, main entrance scrapes splitters.'),
  (st_setsrid(st_makepoint(-75.0705, 39.3590), 4326)::geography, 'a0000000-0000-4000-8000-000000000012',
   'flat', 'large', false, 'Paddock gravel near the far end, park on asphalt.');

-- Market ------------------------------------------------------------------

insert into public.listings (seller_id, kind, title, price_cents, condition, description, fits_make, fits_model, fits_year_from, fits_year_to, region)
values
  ('a0000000-0000-4000-8000-000000000012', 'part', 'Bilstein B6 shocks, set of four', 42000, 'used',
   '20k miles, no leaks. Pickup in South Philly or meet at a Cherry Hill meet.', 'BMW', 'M3', 2001, 2006, 'South Philly'),
  ('a0000000-0000-4000-8000-000000000006', 'part', 'Coil pack set, 1.8T', 8500, 'new',
   'Bought a spare set and never needed it. Still sealed.', 'Volkswagen', 'Jetta', 1999, 2005, 'Haddonfield'),
  ('a0000000-0000-4000-8000-000000000010', 'part', 'Enkei RPF1 17x9 +35, 5x114.3', 95000, 'used',
   'Set of four, minor rash on one. Tires are bald, priced as wheels only.', 'Nissan', '350Z', 2003, 2008, 'Deptford');
