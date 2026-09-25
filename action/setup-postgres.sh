#!/usr/bin/env bash
# Makes Postgres $PG_VERSION server binaries available (initdb, pg_ctl, pg_restore) on a Linux runner.
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "::error::pgdrill's action needs a Linux runner (e.g. ubuntu-latest)"
  exit 2
fi
case "$PG_VERSION" in
  ''|*[!0-9]*) echo "::error::postgres-version must be a major version number like 16, got '$PG_VERSION'"; exit 2 ;;
esac

bin=/usr/lib/postgresql/$PG_VERSION/bin
if [ ! -x "$bin/initdb" ]; then
  echo "installing Postgres $PG_VERSION from apt.postgresql.org"
  sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
  # only the binaries are needed; don't leave a system cluster running
  sudo apt-get install -y -q "postgresql-$PG_VERSION" > /dev/null
  sudo systemctl stop "postgresql@$PG_VERSION-main" 2> /dev/null || true
fi
echo "$bin" >> "$GITHUB_PATH"
"$bin/postgres" --version
