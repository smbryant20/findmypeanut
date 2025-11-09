-- Extensions
raw_text text,
city text, state text, country text,
lat double precision, lng double precision,
geom geography(point),
event_time timestamptz,
contact_email text,
contact_phone text,
status text default 'OPEN',
images text[] default '{}',
created_by uuid references public.users(auth_id),
created_at timestamptz default now()
);


create index if not exists idx_reports_geom on public.reports using gist (geom);
create index if not exists idx_reports_kind on public.reports (kind);
create index if not exists idx_reports_event_time on public.reports (event_time);
create index if not exists idx_reports_trgm on public.reports using gin (raw_text gin_trgm_ops);


-- Embeddings (pgvector)
create type modality as enum ('TEXT','IMAGE');
create table if not exists public.embeddings (
report_id uuid references public.reports(id) on delete cascade,
modality modality not null,
vector vector(768) not null,
primary key (report_id, modality)
);


-- Matches
create table if not exists public.matches (
id uuid primary key default gen_random_uuid(),
lost_report_id uuid not null references public.reports(id) on delete cascade,
found_report_id uuid not null references public.reports(id) on delete cascade,
score double precision not null,
explanation jsonb,
created_at timestamptz default now(),
unique (lost_report_id, found_report_id)
);


-- Flags
create table if not exists public.flags (
id uuid primary key default gen_random_uuid(),
report_id uuid references public.reports(id) on delete cascade,
reason text,
created_by uuid references public.users(auth_id),
created_at timestamptz default now()
);


-- Alert subscriptions
create table if not exists public.alerts (
id uuid primary key default gen_random_uuid(),
auth_id uuid references public.users(auth_id),
email text,
pet_type text check (pet_type in ('DOG','CAT')),
radius_miles int default 10,
center geography(point),
created_at timestamptz default now()
);


-- RLS
alter table public.users enable row level security;
alter table public.reports enable row level security;
alter table public.embeddings enable row level security;
alter table public.matches enable row level security;
alter table public.flags enable row level security;
alter table public.alerts enable row level security;


-- Users: self row
create policy users_self on public.users using (auth.uid() = auth_id) with check (auth.uid() = auth_id);


-- Reports: everyone can read **without PII** via a view; writers can insert own
create view public.reports_public as
select id, kind, pet_id, source, source_url, raw_text,
city, state, country, lat, lng, geom, event_time,
status, images, created_at
from public.reports;


create policy reports_read on public.reports for select using (true);
create policy reports_insert on public.reports for insert with check (auth.uid() = created_by or created_by is null);
create policy reports_update_own on public.reports for update using (auth.uid() = created_by);


-- Embeddings readable, updatable by owner/admin only
create policy embeddings_owner on public.embeddings for all using (
exists(select 1 from public.reports r where r.id = report_id and (r.created_by = auth.uid()))
) with check (
exists(select 1 from public.reports r where r.id = report_id and (r.created_by = auth.uid()))
);


-- Matches readable to all
create policy matches_read on public.matches for select using (true);


-- Alerts: owner only
create policy alerts_owner on public.alerts using (auth.uid() = auth_id) with check (auth.uid() = auth_id);