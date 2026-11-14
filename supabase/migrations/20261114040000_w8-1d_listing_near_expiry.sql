-- W8-1D MKT-1: a coarse position for the distance filter. MKT-9: listing expiry and relist.
--
-- lat_c / lng_c are the listing's position rounded to 0.1 degree (about 11 km), written by
-- the client at creation. Browse filters on a bounding box over them; that is all the
-- precision the filter claims. h3_r5 stays unused (Postgres has no H3 extension).
--
-- updated_at is touched whenever the seller changes the row. Browse leaves out active
-- listings with updated_at older than 90 days; the seller sees them as "Expired" and can
-- call relist_listing(listing), which makes the row active again and resets the clock.

alter table public.listings
  add column lat_c double precision check (lat_c between -90 and 90),
  add column lng_c double precision check (lng_c between -180 and 180),
  add column updated_at timestamptz;

update public.listings set updated_at = created_at where updated_at is null;
alter table public.listings alter column updated_at set default now();
alter table public.listings alter column updated_at set not null;

create index listings_coarse_idx on public.listings (lat_c, lng_c) where status = 'active';
create index listings_active_updated_idx on public.listings (status, updated_at desc);

-- The server rounds whatever the client sent to 0.1 degree. Only the seller's own edits
-- count as a touch; moderation (hidden_at) does not.
create or replace function public.listings_touch()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.lat_c := round(new.lat_c::numeric, 1)::double precision;
  new.lng_c := round(new.lng_c::numeric, 1)::double precision;
  if tg_op = 'INSERT' then
    new.updated_at := now();
  elsif auth.uid() is not null and auth.uid() = new.seller_id then
    new.updated_at := now();
  else
    new.updated_at := old.updated_at;
  end if;
  return new;
end;
$$;

create trigger listings_touch before insert or update on public.listings
  for each row execute function public.listings_touch();

create or replace function public.relist_listing(listing uuid)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  update public.listings
     set status = 'active', updated_at = now()
   where id = listing and seller_id = auth.uid() and status in ('active', 'pending');
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;
end;
$$;

revoke all on function public.relist_listing(uuid) from public, anon;
grant execute on function public.relist_listing(uuid) to authenticated;
