-- W0-C: extensions and enum types (plan section 5).

create extension if not exists postgis with schema extensions;
create extension if not exists citext with schema extensions;

create type public.share_level as enum ('precise', 'approx', 'hidden');
create type public.device_environment as enum ('sandbox', 'production');
create type public.friendship_status as enum ('pending', 'accepted');
create type public.car_clearance as enum ('stock', 'lowered', 'slammed');

create type public.report_kind as enum (
  'speed_bump', 'steep_entrance', 'pothole', 'rough_road',
  'police', 'hazard', 'closure', 'fuel_e85'
);
create type public.meet_kind as enum ('meet', 'cruise', 'hangout', 'track_day', 'show');
create type public.meet_visibility as enum ('public', 'friends', 'team');
create type public.rsvp_status as enum ('going', 'maybe');
create type public.entrance_grade as enum ('flat', 'moderate', 'steep');
create type public.lot_size as enum ('small', 'medium', 'large');

create type public.channel_kind as enum ('text', 'voice');
create type public.thread_kind as enum ('dm', 'listing');

create type public.showdown_class as enum ('street', 'built', 'show', 'classic');
create type public.listing_kind as enum ('part', 'car');
create type public.listing_condition as enum ('new', 'used', 'for_parts');
create type public.listing_status as enum ('active', 'pending', 'sold', 'removed');
create type public.content_reason as enum (
  'spam', 'harassment', 'nudity', 'dangerous_driving', 'scam', 'other'
);
