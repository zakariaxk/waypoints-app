-- W7-6 MKT-8: "Wanted" listings. A wanted listing's price_cents is the poster's budget.

alter type public.listing_kind add value if not exists 'wanted';
