-- L82 (MKT-11): a price drop on a saved listing tells every saver. One activity row per
-- saver, opening the listing; the seller is skipped by record_notification's actor check.

create or replace function public.on_price_drop_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s record;
begin
  if new.status = 'active' and new.price_cents < old.price_cents then
    for s in select user_id from public.listing_saves where listing_id = new.id
    loop
      perform public.record_notification(s.user_id, 'price_drop', new.seller_id,
        'waypoints://listing/' || new.id,
        'A saved listing dropped to $' || to_char(new.price_cents / 100.0, 'FM999G999G990'),
        new.title, 'price_drop:' || new.id || ':' || new.price_cents);
    end loop;
  end if;
  return new;
end;
$$;
create trigger listings_price_drop_notify after update of price_cents on public.listings
  for each row execute function public.on_price_drop_notify();
