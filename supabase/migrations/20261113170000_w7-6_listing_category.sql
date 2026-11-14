-- W7-6 MKT-7: part categories on listings.

create type public.listing_category as enum (
  'wheels_tires', 'exhaust', 'intake_fuel', 'forced_induction', 'engine', 'drivetrain', 'suspension', 'brakes',
  'exterior_aero', 'interior', 'lighting', 'electronics_tuning', 'tools', 'apparel', 'other'
);

alter table public.listings add column category public.listing_category;

create index listings_category_idx on public.listings (kind, category, created_at desc) where status = 'active';
