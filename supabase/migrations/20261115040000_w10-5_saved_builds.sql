-- W10-5 (MOD-15): saved builds. Up to three named mod sets per car, kept with the car as
-- [{"id": uuid, "name": text, "mods": [mod ids]}]. A column on `cars`, so the existing cars
-- policies apply unchanged: owner-only write, read exactly where the car's mods are read
-- (blocks, hidden_at and suspension respected), nothing for anon.

alter table public.cars
  add column saved_builds jsonb not null default '[]'
  check (case when jsonb_typeof(saved_builds) = 'array'
              then jsonb_array_length(saved_builds) <= 3 and octet_length(saved_builds::text) <= 4000
              else false end);
