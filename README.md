# pgdrill

**Prove your Postgres backups actually restore — complete, correct and fresh.**

Most teams have backups. Few regularly check that one restores, and "it restored
without errors" is not the same as "it's right". In our tests, `pg_restore`
reported success for **4 of 6 kinds of broken backup** (a missing table, a
table with no data, lost sequence positions, a stale backup). pgdrill catches
all of them.

pgdrill restores a backup into a throwaway Postgres server, compares it with
production and tells you, with evidence, whether you could rely on it.

Real output, drilling a backup of GitLab's production schema:

```
$ pgdrill run gitlab.dump --baseline gitlab-baseline.json
backup    gitlab.dump (custom, 7.2 MB, from Postgres 16.15)
baseline  gitlab-baseline.json (captured 2026-09-25T09:47:31Z)

restore   ok in 3.0s
schema    27751 objects match production
rows      1357 tables within tolerance
freshness newest data 2026-09-25T09:45:17Z (2.4m old)
sequences 973 checked
amcheck   5862 indexes clean

PASS
```

> **Status: pre-release (v0.1 in development).** The gem and Docker images are
> not published yet; until then, run from a clone: `git clone
> https://github.com/mitkush/pgdrill && pgdrill/exe/pgdrill run …` or build the
> image with `docker build -f docker/Dockerfile --build-arg PG_MAJOR=16 -t pgdrill:pg16 .`

## What it checks

| Check | Catches |
|---|---|
| **restore** | truncated/corrupt files, missing extensions, broken dumps |
| **schema** | tables, columns, indexes, constraints, views or sequences missing from the backup |
| **rows** | tables that came back empty or far smaller than production |
| **freshness** | backups older than production's data (`--lag-tolerance`) or than a limit you set (`--max-age`) |
| **sequences** | sequences behind their column, so the first `INSERT` after a restore would fail with a duplicate key |
| **amcheck** | btree index corruption (`bt_index_check` with `heapallindexed`) |

Problems that already exist in production (e.g. a sequence already behind its
column) are reported as notes, not blamed on the backup.

## Quick start

**1. Record what production looks like, just before the backup starts**
(read-only, safe for production and read replicas). The backup then has to
contain everything the baseline saw; data written while `pg_dump` runs is
simply newer and doesn't count against it.

```sh
export PGDRILL_DB="postgresql://pgdrill@db.internal/app"   # password via PGPASSWORD or ~/.pgpass
pgdrill baseline -o baseline.json
pg_dump -Fc -f nightly.dump "$PGDRILL_DB"
```

**2. Drill the backup** (anywhere with Docker, e.g. a nightly CI job):

```sh
docker run --rm -v "$PWD:/work:ro" ghcr.io/mitkush/pgdrill:pg16 \
  run /work/nightly.dump --baseline /work/baseline.json --max-age 26h
```

Pick the image tag for the Postgres major version your backup came from
(`pg15`, `pg16`, `pg17`); it must be at least as new as both the source server
and the `pg_dump` that wrote the backup, and pgdrill stops with exit code 2 if it isn't.

Exit codes: `0` = PASS (or WARN: nothing critical, but see the warnings), `1` =
the backup failed a check, `2` = pgdrill itself couldn't run (bad arguments,
missing Postgres binaries, restore server too old).

No baseline? `pgdrill run nightly.dump --max-age 26h` still checks that the
backup restores, is recent, has intact indexes and sane sequences.

### Where the backup can live

```sh
pgdrill run nightly.dump                          # local file
pgdrill run s3://backups/db/2026-09-25.dump       # one S3 object
pgdrill run s3://backups/db/                      # the newest object under a prefix (or add --latest)
pgdrill run "$(aws s3 presign s3://backups/db/x.dump)"   # any https:// URL, e.g. presigned
```

`s3://` reads `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, optional
`AWS_SESSION_TOKEN` and `AWS_REGION`; set `AWS_ENDPOINT_URL` for Cloudflare R2,
Backblaze B2 or another S3-compatible store (tested against RustFS). For IAM
roles or SSO, pass a presigned URL instead. Downloads go to a private temporary
directory that is deleted after the run, and URL query strings (where presigned
signatures live) are never printed or written to reports.

### In GitHub Actions

```yaml
on:
  schedule: [{ cron: "0 6 * * *" }]   # every morning, after the nightly backup
jobs:
  drill:
    runs-on: ubuntu-latest
    steps:
      - uses: mitkush/pgdrill@main    # pin a release tag once one exists
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.BACKUP_READ_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.BACKUP_READ_SECRET }}
          AWS_REGION: eu-west-1
        with:
          backup: s3://my-backups/nightly/
          baseline-db: ${{ secrets.REPLICA_READONLY_URL }}
          max-age: 26h
```

The step fails when the backup fails the drill, writes the results to the job
summary, and sets `verdict` (PASS/WARN/FAIL) and `report` (JSON path) outputs.
It installs the requested `postgres-version` (default 17, which can restore
backups from any older version) on the Linux runner; no image or gem needed.
A live `baseline-db` here is taken after the backup, so allow for writes since
then with `lag-tolerance` (or upload a baseline file taken just before the backup).

### Without Docker

```sh
gem install pgdrill          # Ruby >= 3.1, no other gem dependencies
pgdrill run nightly.dump --baseline baseline.json
```

This needs Postgres server binaries (`initdb`, `pg_ctl`, `pg_restore`) on your
`PATH`, at least as new as the backup. Or restore into an existing server with
`--target` / `PGDRILL_TARGET` (Postgres 13+, needs `CREATEDB` and `CREATEROLE`;
roles the backup references are created there as `NOLOGIN`, and the restored
database is dropped afterwards unless you pass `--keep`).

Tested with Postgres 15, 16 and 17.

## Supported backups

`pg_dump` custom (`-Fc`), directory (`-Fd`) and tar (`-Ft`) archives, plain SQL
(`.sql`) and gzipped plain SQL (`.sql.gz`).

Not yet: physical backups (pgBackRest, WAL-G, `pg_basebackup`), managed-database
snapshots (RDS, Cloud SQL), MySQL. Directory-format (`-Fd`) backups only from
local paths, since they are folders rather than single objects.

## Safety

- **Production is only read.** `baseline` and `--baseline-db` use a read-only
  session with a statement timeout. Exact row counts only for small tables
  (`--exact-row-limit`, default 100k); larger tables use planner estimates.
  Freshness reads only indexed timestamp columns, so it never scans a table.
- **Credentials**: pgdrill hands them to `psql` through environment variables,
  never on its command line. Keep them off *pgdrill's* command line too: use
  `PGDRILL_DB` / `PGDRILL_BASELINE_DB` / `PGDRILL_TARGET` without a password,
  plus `PGPASSWORD` or `~/.pgpass`.
- **The restored copy is protected**: the throwaway server listens only on
  127.0.0.1, requires a random per-run password, and keeps its data in a
  private (0700) temporary directory that is deleted after the run.
  It runs with `fsync=off` for speed; it is never used for anything else.
- **Nothing leaves your machine**: no telemetry, no uploads.
- **Only drill backups you trust.** Restoring a backup executes its SQL as a
  superuser of the throwaway server, which can run programs as the user running
  pgdrill. Run it in the Docker image to contain that.

A minimal role for baselines:

```sql
create role pgdrill login password '...';
grant pg_read_all_data to pgdrill;  -- Postgres 14+
```

## JSON report and audit evidence

`--format json` (or `--output report.json`) records the measured restore time
and data age with timestamps: evidence that restore testing happened, which
audits such as SOC 2 and ISO 27001 ask for. `--summary FILE` appends a Markdown
version (e.g. to `$GITHUB_STEP_SUMMARY`). `--fail-on-warn` makes warnings fail too.

## Known limitations

- Without a row estimate on a replica (a never-analyzed table), a large table's
  row count is recorded as unknown and not compared.
- IDs generated by functions (e.g. Mastodon's snowflake `timestamp_id()`) are
  not covered by the sequence check.
- Ownership, grants and tablespaces are not restored (`--no-owner
  --no-privileges --no-tablespaces`), so they are not verified.
- Freshness needs at least one timestamp column with an index.

## How it's tested

Every change runs the [scenario harness](test/scenarios/run.rb): it breaks
real backups on purpose (truncated file, missing table, missing data, lost
sequence positions, stale backup) and requires each to be classified
correctly, on Pagila (Postgres 15/16/17), GitLab's production schema
(1,357 tables), a real Mastodon database and Postgres's own regression-test
database.

```sh
bundle exec rake test                                                  # unit tests
PGDRILL_SCENARIO_DB=postgresql://postgres@127.0.0.1:55432/pagila \
  bundle exec rake scenarios                                           # needs a disposable database
```

## License

MIT
