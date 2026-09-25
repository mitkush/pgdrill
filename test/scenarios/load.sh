#!/usr/bin/env bash
# Usage: load.sh <pagila|gitlab|mastodon|regression> — loads a real-world database into
# the "production" cluster on 127.0.0.1:55432 (started by start-prod.sh).
set -euo pipefail
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres

case "$1" in
  pagila)
    ref=e0e35a666f # last Pagila revision that loads on Postgres < 18
    for f in schema data; do curl -sfLO "https://raw.githubusercontent.com/devrimgunduz/pagila/$ref/pagila-$f.sql"; done
    createdb pagila
    psql -X -q -d pagila -v ON_ERROR_STOP=1 -f pagila-schema.sql > /dev/null
    psql -X -q -d pagila -v ON_ERROR_STOP=1 -f pagila-data.sql > /dev/null
    # a recently added table with no dependents, like real apps grow
    psql -X -q -d pagila -c "create table audit_log (id bigserial primary key, action text not null, created_at timestamptz not null default now())" \
                          -c "insert into audit_log (action) select 'seed' from generate_series(1, 1000)" -c "analyze"
    bash "$(dirname "$0")/edge-cases.sql.sh" pagila
    ;;
  gitlab)
    curl -sfL -o structure.sql https://gitlab.com/gitlab-org/gitlab/-/raw/master/db/structure.sql
    createdb gitlab
    psql -X -q -d gitlab -v ON_ERROR_STOP=1 -f structure.sql > /dev/null
    ;;
  mastodon)
    docker run -d --network host --name redis redis:7-alpine > /dev/null
    createdb mastodon
    cat > seed.rb <<'RUBY'
    # production mode rejects test email domains (MX lookup), so skip validation for seed users only
    mk = ->(name) do
      u = User.new(email: "#{name}@example.com", password: SecureRandom.hex(16), agreement: true,
                   confirmed_at: Time.now.utc, approved: true, account: Account.new(username: name))
      u.save!(validate: false)
      u.account
    end
    alice = mk.("alice"); bob = mk.("bob")
    FollowService.new.call(bob, alice)
    30.times { |i| PostStatusService.new.call(alice, text: "hello world #{i} #drill") }
    10.times { |i| s = PostStatusService.new.call(bob, text: "reply #{i}"); FavouriteService.new.call(alice, s) }
    puts "accounts=#{Account.count} statuses=#{Status.count}"
RUBY
    docker run --rm --network host -v "$PWD/seed.rb:/opt/seed.rb:ro" \
      -e RAILS_ENV=production -e LOCAL_DOMAIN=example.com -e DISABLE_DATABASE_ENVIRONMENT_CHECK=1 -e ES_ENABLED=false \
      -e DB_HOST=127.0.0.1 -e DB_PORT=55432 -e DB_USER=postgres -e DB_PASS= -e DB_NAME=mastodon \
      -e REDIS_HOST=127.0.0.1 -e REDIS_PORT=6379 \
      -e SECRET_KEY_BASE="$(openssl rand -hex 64)" -e OTP_SECRET="$(openssl rand -hex 64)" \
      -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)" \
      -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)" \
      -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)" \
      ghcr.io/mastodon/mastodon:v4.7.2 bash -c 'bundle exec rails db:setup && bundle exec rails runner /opt/seed.rb'
    ;;
  geo)
    # PostGIS + pgvector (needs postgresql-N-postgis-3 and postgresql-N-pgvector installed)
    createdb geo
    psql -X -q -d geo -v ON_ERROR_STOP=1 <<'SQL'
create extension postgis;
create extension vector;
create table places (id bigserial primary key, name text not null, geom geometry(Point, 4326) not null,
                     created_at timestamptz not null default now());
insert into places (name, geom)
  select 'place ' || g, ST_SetSRID(ST_MakePoint(random() * 360 - 180, random() * 180 - 90), 4326)
    from generate_series(1, 5000) g;
create index places_geom on places using gist (geom);
create table embeddings (id bigserial primary key, doc text not null, embedding vector(3) not null,
                         created_at timestamptz not null default now());
insert into embeddings (doc, embedding)
  select 'doc ' || g, format('[%s,%s,%s]', random(), random(), random())::vector from generate_series(1, 5000) g;
create index embeddings_hnsw on embeddings using hnsw (embedding vector_l2_ops);
analyze;
SQL
    ;;
  regression)
    # needs Postgres built from source (regress.so); PG_SRC points at the configured source tree
    make -C "$PG_SRC/src/test/regress" installcheck > regress.log 2>&1 || echo "(some regression tests failed; harmless, we only need the leftover database)"
    ;;
  *) echo "unknown dataset $1" >&2; exit 2 ;;
esac
echo "loaded $1"
