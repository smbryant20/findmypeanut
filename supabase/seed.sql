insert into public.users (auth_id, role) values ('11111111-1111-1111-1111-111111111111','admin') on conflict do nothing;


-- LOST dog
insert into public.reports (id, kind, raw_text, city, state, country, lat, lng, geom, event_time, images, created_by)
values (
'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'LOST', 'Brown lab mix with white chest, blue collar, last seen near Elm St.',
'North Adams','MA','USA',42.7008,-73.1087, ST_SetSRID(ST_MakePoint(-73.1087,42.7008),4326)::geography,
now() - interval '1 day', ARRAY['https://picsum.photos/seed/lostdog/600/400'], '11111111-1111-1111-1111-111111111111'
);


-- FOUND dog
insert into public.reports (id, kind, raw_text, city, state, country, lat, lng, geom, event_time, images, created_by)
values (
'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'FOUND', 'Found brown dog with blue collar by the river trail',
'North Adams','MA','USA',42.7020,-73.1100, ST_SetSRID(ST_MakePoint(-73.1100,42.7020),4326)::geography,
now() - interval '10 hours', ARRAY['https://picsum.photos/seed/founddog/600/400'], '11111111-1111-1111-1111-111111111111'
);