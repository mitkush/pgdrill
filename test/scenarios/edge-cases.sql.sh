#!/usr/bin/env bash
# Usage: edge-cases.sql.sh <db> — adds production features that once made healthy backups look broken.
set -euo pipefail
psql -X -q -v ON_ERROR_STOP=1 -d "$1" <<'SQL'
-- Row-level security for roles that only exist on the production server (Supabase style).
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
alter table audit_log enable row level security;
create policy read_own on audit_log for select to authenticated, anon using (true);

-- A large table Postgres has never analyzed (reltuples = -1): must not be counted exactly on production.
create table zz_unanalyzed (id bigint, pad text) with (autovacuum_enabled = false);
insert into zz_unanalyzed select g, repeat('x', 100) from generate_series(1, 300000) g;
SQL
