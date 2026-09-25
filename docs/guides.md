# pgdrill guides

Each setup says whether it is **tested in pgdrill's CI** or **not tested by us**
(commands for a provider we have no account with). Please report anything
that doesn't work.

## The nightly pattern

Every setup below follows the same three steps:

1. **Baseline, then backup.** Right before `pg_dump` starts, record what
   production looks like. The backup then has to contain everything the
   baseline saw; data written while the dump runs is simply newer.
2. **Store both** where the drill can reach them: same machine, or S3 with the
   baselines under their own prefix.
3. **Drill later**, anywhere with Docker or on a GitHub-hosted runner, and
   alert when something is wrong.

## Backup job: baseline + dump + upload to S3

*Each command here is exercised in CI (`pgdrill baseline`, `pg_dump`, uploads to an S3-compatible server); this script as a whole is not.*

```sh
#!/usr/bin/env bash
set -euo pipefail
export PGDRILL_DB="postgresql://pgdrill@db.internal/app"   # password in ~/.pgpass
day=$(date -u +%F)

pgdrill baseline -o "baseline-$day.json"                    # 1. baseline first
pg_dump -Fc -f "app-$day.dump" "$PGDRILL_DB"               # 2. then the backup

aws s3 cp "baseline-$day.json" "s3://my-backups/baselines/$day.json"
aws s3 cp "app-$day.dump" "s3://my-backups/nightly/app-$day.dump"
```

## Drill with cron and Docker

*pgdrill's S3 sources (backups and baselines) and webhook alerts are tested in CI, and so is the image; this cron line, and the image reading from S3, are not.*

```sh
# /etc/cron.d/pgdrill: 06:00 UTC every day, alert Slack on problems
0 6 * * * root docker run --rm --env-file /etc/pgdrill.env ghcr.io/mitkush/pgdrill:pg16 run s3://my-backups/nightly/ --baseline s3://my-backups/baselines/ --max-age 26h
```

```sh
# /etc/pgdrill.env (chmod 600): read-only S3 credentials and the Slack webhook
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=eu-west-1
PGDRILL_WEBHOOK=https://hooks.slack.com/services/...
```

`s3://…/nightly/` drills the newest backup (baseline `.json` files are never
picked as the backup), and `--baseline s3://…/baselines/` uses the newest
baseline. `--max-age 26h` fails the drill if the backup job silently stopped
running. Use the `-extras` image if the database uses PostGIS or pgvector.

## Drill with GitHub Actions

*Tested in CI: the Action with S3 credentials on the step, a baseline and config read as here, and the `extensions` input (in a separate job). The webhook secret is passed the same way but not tested through the Action.*

```yaml
name: backup drill
on:
  schedule: [{ cron: "0 6 * * *" }]
  workflow_dispatch:
jobs:
  drill:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v5        # only needed for a pgdrill.yml in the repo
      - uses: mitkush/pgdrill@main       # pin a release tag once one exists
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.BACKUP_READ_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.BACKUP_READ_SECRET }}
          AWS_REGION: eu-west-1
          PGDRILL_WEBHOOK: ${{ secrets.SLACK_WEBHOOK_URL }}
        with:
          backup: s3://my-backups/nightly/
          baseline: s3://my-backups/baselines/
          max-age: 26h
          config: pgdrill.yml                  # optional custom checks
          extensions: postgis, vector          # only if the database uses them
```

The job fails when the backup fails the drill, and the results appear in the
job summary. For failed scheduled runs, GitHub notifies whoever last edited the
schedule, depending on their notification settings.

## Hosted Postgres

**Any provider (RDS, Cloud SQL, Azure, Neon, Supabase, Render, Heroku, ...)**:
the tested path is to run `pg_dump` yourself against the connection string,
as in the backup job above. Use a `pg_dump` at least as new as the server.

**Heroku** *(not tested by us)*: Heroku's own backups are `pg_dump`
custom-format archives, and `heroku pg:backups:url` prints a temporary
download URL for the latest one, which pgdrill can drill directly:

```sh
pgdrill run "$(heroku pg:backups:url --app my-app)" --max-age 26h
```

**Supabase** *(not tested by us)*: Supabase databases can use extensions of
their own (for example `pg_graphql`). If pgdrill's throwaway server doesn't have
one, the drill stops with exit code 2 and names it rather than failing the
backup; restore into a server that has them with `--target`.

**Managed snapshots (RDS, Cloud SQL)** aren't `pg_dump` files, so pgdrill can't
read them; take a `pg_dump` alongside them instead.

## A useful pgdrill.yml

*The format is tested in CI; the queries are examples to adapt.*

```yaml
checks:
  - name: the backup has yesterday's signups
    sql: select count(*) from users where created_at > now() - interval '1 day'
    expect: "> 0"
  - name: no orders without a customer
    sql: select count(*) from orders o left join customers c on c.id = o.customer_id where c.id is null
    expect: "= 0"
rows:
  tables:
    public.events: 50%       # pruned daily, so counts move a lot
ignore_tables:
  - public.sessions          # recreated constantly; not worth comparing
```
