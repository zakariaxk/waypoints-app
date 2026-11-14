-- W7-4 (PRD RPT-9): speed camera and red-light camera reports. Permanent and confirmable like a
-- speed bump: public.report_lifetime returns null for both, so reports_defaults marks them
-- permanent. There is no checkpoint kind and never will be.
-- Own file: a new enum value cannot be used in the transaction that adds it.

alter type public.report_kind add value if not exists 'speed_camera';
alter type public.report_kind add value if not exists 'red_light_camera';
