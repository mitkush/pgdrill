#!/usr/bin/env bash
# Makes Postgres $PG_VERSION server binaries (initdb, pg_ctl, pg_restore) available on a Linux runner,
# plus the extensions listed in $PG_EXTENSIONS (postgis, vector).
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "::error::pgdrill's action needs a Linux runner (e.g. ubuntu-latest)"
  exit 2
fi
case "$PG_VERSION" in
  ''|*[!0-9]*) echo "::error::postgres-version must be a major version number like 18, got '$PG_VERSION'"; exit 2 ;;
esac

packages=()
bin=/usr/lib/postgresql/$PG_VERSION/bin
[ -x "$bin/initdb" ] || packages+=("postgresql-$PG_VERSION")
IFS=', ' read -r -a wanted <<< "${PG_EXTENSIONS:-}"
for ext in "${wanted[@]}"; do
  case "$ext" in
    '') ;;
    postgis) packages+=("postgresql-$PG_VERSION-postgis-3") ;;
    vector|pgvector) packages+=("postgresql-$PG_VERSION-pgvector") ;;
    *) echo "::error::unsupported extension '$ext' (supported: postgis, vector); for others use --target with a server that has it"; exit 2 ;;
  esac
done

if [ ${#packages[@]} -gt 0 ]; then
  echo "installing ${packages[*]} from apt.postgresql.org"
  sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y > /dev/null
  sudo apt-get install -y -q "${packages[@]}" > /dev/null
  # only the binaries are needed; don't leave a system cluster running
  sudo systemctl stop "postgresql@$PG_VERSION-main" 2> /dev/null || true
fi
echo "$bin" >> "$GITHUB_PATH"
"$bin/postgres" --version
