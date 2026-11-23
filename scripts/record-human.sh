#!/usr/bin/env bash
# Record the human backport of a case into cases/<case>/human/ (never mounted).
# Usage: record-human.sh [<case|all> ...] [--force] [--check]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

args=()
for arg in "$@"; do
  case "$arg" in
    --force|--check) args+=("$arg") ;;
    all) args+=("all") ;;
    *) require_case "$arg"; args+=("$arg") ;;
  esac
done
if [ "${#args[@]}" -eq 0 ]; then
  mapfile -t cases < <(case_names)
  args=("${cases[@]}")
fi
python3 "$BENCH_DIR/scripts/record_human.py" "${args[@]}"
