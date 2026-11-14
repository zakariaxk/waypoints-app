-- W8-1C (GAR-16): service log. A build entry can be marked as service with an odometer
-- reading (in the unit the owner entered) and an optional reminder date; the reminder is a
-- local notification scheduled on the owner's device, so nothing here sends it.

alter table public.build_entries
  add column is_service boolean not null default false,
  add column odometer int check (odometer between 0 and 9999999),
  add column odometer_unit text check (odometer_unit in ('mi', 'km')),
  add column remind_on date,
  add constraint build_entries_service_fields check (
    is_service or (odometer is null and remind_on is null)
  );
