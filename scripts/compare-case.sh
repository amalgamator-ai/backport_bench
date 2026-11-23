#!/usr/bin/env bash
# Compare the AI result of one run against the case's reference backport.
# Runs on the host; the reference is never mounted into a run container.
# Usage: compare-case.sh <case> <run-dir> [judge args...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case="${1:?usage: compare-case.sh <case> <run-dir>}"
run="${2:?usage: compare-case.sh <case> <run-dir>}"
shift 2
require_case "$case"
[ -d "$run" ] || die "no such run directory: $run"
py="$AMALGAMATOR/.venv/bin/python"
[ -x "$py" ] || die "amalgamator venv missing: $py"
exec "$py" "$BENCH_DIR/scripts/judge.py" "$case" "$run" "$@"
