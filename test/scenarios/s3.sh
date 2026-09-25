#!/usr/bin/env bash
# S3 integration test against a real S3-compatible server (RustFS) on 127.0.0.1:9000.
# Needs: the "production" cluster with pagila (start-prod.sh + load.sh), aws CLI, AWS_* env set for the server.
set -uo pipefail
export PGHOST=127.0.0.1 PGPORT=55432 PGUSER=postgres
ROOT=$(cd "$(dirname "$0")/../.." && pwd) # resolve before cd-ing into the work dir
PGDRILL="ruby $ROOT/exe/pgdrill"
work=$(mktemp -d); cd "$work"
fails=0
check() { # name, expected exit, actual exit, [grep pattern in output]
  local ok=1
  [ "$2" = "$3" ] || ok=0
  if [ -n "${4:-}" ] && ! grep -qE "$4" out.txt; then ok=0; fi
  if [ $ok = 1 ]; then echo "ok     $1"; else echo "WRONG  $1 (expected exit $2${4:+ and /$4/}, got $3)"; sed 's/^/       | /' out.txt | tail -5; fails=$((fails+1)); fi
}
run() { $PGDRILL run "$@" --baseline baseline.json --format json --output report.json > out.txt 2>&1; echo $?; }

pg_dump -Fc -d pagila -f good.dump
head -c 300000 good.dump > broken.dump
$PGDRILL baseline --db postgresql://postgres@127.0.0.1:55432/pagila -o baseline.json > /dev/null

aws s3 mb s3://drill > /dev/null
aws s3 cp broken.dump s3://drill/nightly/2026-09-24.dump --quiet; sleep 2
aws s3 cp good.dump s3://drill/nightly/2026-09-25.dump --quiet

code=$(run s3://drill/nightly/)
check "prefix → newest backup (good) passes" 0 "$code" '"location": "s3://drill/nightly/2026-09-25.dump"'

n=$(ruby -I "$ROOT/lib" -rpgdrill -e 'print Pgdrill::S3.from_env.list("drill", "nightly/", page_size: 1).size')
[ "$n" = 2 ] && echo "ok     listing follows pagination (2 objects, 1 per page)" || { echo "WRONG  paginated listing returned $n objects, expected 2"; fails=$((fails+1)); }

code=$(run s3://drill/nightly/2026-09-24.dump)
check "explicit key (broken) fails" 1 "$code" '"verdict": "FAIL"'

sleep 2; aws s3 cp broken.dump s3://drill/nightly/2026-09-26.dump --quiet
code=$(run s3://drill/nightly --latest)
check "--latest picks the newer broken backup and fails" 1 "$code" '2026-09-26.dump'

# Baselines stored in S3, and a baseline .json that is the newest object next to the dumps.
aws s3 cp baseline.json s3://drill/baselines/2026-09-27.json --quiet
sleep 2; aws s3 cp good.dump s3://drill/nightly/2026-09-27.dump --quiet
sleep 2; aws s3 cp baseline.json s3://drill/nightly/2026-09-27.baseline.json --quiet
$PGDRILL run s3://drill/nightly/ --baseline s3://drill/baselines/ --format json --output report.json > out.txt 2>&1; code=$?
check "baseline from an S3 prefix; newest .json next to the dumps is skipped" 0 "$code" '"location": "s3://drill/nightly/2026-09-27.dump"'
grep -q '"source": "s3://drill/baselines/2026-09-27.json"' report.json && echo "ok     report names the S3 baseline" || { echo "WRONG  report doesn't name the S3 baseline"; fails=$((fails+1)); }

url=$(aws s3 presign s3://drill/nightly/2026-09-25.dump --expires-in 600)
code=$(run "$url")
check "presigned URL passes" 0 "$code" '"verdict": "PASS"'
if grep -q "X-Amz-Signature" report.json out.txt; then echo "WRONG  presigned signature leaked into the report"; fails=$((fails+1)); else echo "ok     presigned signature not in report or output"; fi

code=$(AWS_SECRET_ACCESS_KEY=wrong run s3://drill/nightly/2026-09-25.dump)
check "wrong credentials are a tool error, not a failed backup" 2 "$code" 'SignatureDoesNotMatch|InvalidAccessKeyId|AccessDenied|403'

code=$(run s3://drill/nightly/nope.dump)
check "missing key is a tool error" 2 "$code" 'NoSuchKey|404'

code=$(run s3://drill/empty/)
check "empty prefix is a tool error" 2 "$code" 'no backups found'

leftover=$(ls -d "${TMPDIR:-/tmp}"/pgdrill-src-* 2> /dev/null | wc -l)
[ "$leftover" -eq 0 ] && echo "ok     downloads cleaned up" || { echo "WRONG  $leftover download dir(s) left behind"; fails=$((fails+1)); }

echo; [ $fails -eq 0 ] && echo "all S3 checks passed" || echo "$fails S3 check(s) failed"
exit $fails
