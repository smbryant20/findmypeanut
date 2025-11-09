# Finder (Flutter + Supabase)


**Goal:** MVP for lost/found pet matching. Flutter app (violet theme), Supabase backend with PostGIS/pgvector, Edge Functions for APIs, scheduled matching.


## Prereqs
- Flutter 3.22+
- Supabase project (Postgres 15+), enable **PostGIS** / **pgvector** / **pg_trgm**
- VS Code recommended


## Setup
1. Clone repo, copy env:
```bash
cp .env.example .env