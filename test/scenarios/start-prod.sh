#!/usr/bin/env bash
# Usage: start-prod.sh <postgres bin dir> — starts the "production" cluster on 127.0.0.1:55432.
set -euo pipefail
BIN=$1
DATA=${RUNNER_TEMP:-/tmp}/pgdrill-prod
"$BIN/initdb" -D "$DATA" -U postgres --auth=trust --no-locale -E UTF8 > /dev/null
"$BIN/pg_ctl" -D "$DATA" -l "$DATA.log" -w \
  -o "-p 55432 -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp" start > /dev/null
echo "production cluster (Postgres $("$BIN/postgres" --version | awk '{print $3}')) on 127.0.0.1:55432"
