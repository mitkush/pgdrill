#!/usr/bin/env bash
# Runs `pgdrill run` from the action's own checkout (no gem or image needed) and exposes the result.
set -uo pipefail

report=$(mktemp -p "$RUNNER_TEMP" --suffix=.json pgdrill-report-XXXXXX) # one per step: a job may drill several backups
args=(run "$INPUT_BACKUP" --output "$report" --summary "$GITHUB_STEP_SUMMARY")
[ -n "$INPUT_BASELINE" ] && args+=(--baseline "$INPUT_BASELINE")
[ -n "$INPUT_MAX_AGE" ] && args+=(--max-age "$INPUT_MAX_AGE")
[ -n "$INPUT_LAG_TOLERANCE" ] && args+=(--lag-tolerance "$INPUT_LAG_TOLERANCE")
[ "$INPUT_FAIL_ON_WARN" = "true" ] && args+=(--fail-on-warn)
# PGDRILL_BASELINE_DB is read from the environment, keeping the URL out of argv and logs.
[ -z "${PGDRILL_BASELINE_DB:-}" ] && unset PGDRILL_BASELINE_DB

ruby "$GITHUB_ACTION_PATH/exe/pgdrill" "${args[@]}"
code=$?

verdict=ERROR
[ -s "$report" ] && verdict=$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["verdict"]' "$report")
echo "verdict=$verdict" >> "$GITHUB_OUTPUT"
echo "report=$report" >> "$GITHUB_OUTPUT"

case $code in
  0) ;;
  1) echo "::error::pgdrill: the backup failed the drill ($verdict), see the job summary" ;;
  *) echo "::error::pgdrill could not run the drill (exit $code), see the log above" ;;
esac
exit $code
