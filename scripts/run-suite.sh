#!/usr/bin/env bash
# Run cases with bounded concurrency. Usage: run-suite.sh [--parallel N] [--cases a,b] [case...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

parallel=3
cases=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --parallel) parallel="$2"; shift 2 ;;
    --cases) IFS=',' read -r -a cases <<< "$2"; shift 2 ;;
    *) cases+=("$1"); shift ;;
  esac
done
[ "${#cases[@]}" -gt 0 ] || mapfile -t cases < <(case_names)

running=0
pids=()
for c in "${cases[@]}"; do
  while [ "$running" -ge "$parallel" ]; do
    wait -n || true
    running=$((running - 1))
  done
  echo "launch $c"
  "$BENCH_DIR/scripts/run-case.sh" "$c" &
  pids+=($!)
  running=$((running + 1))
done
wait || true
"$BENCH_DIR/scripts/summarize.py"
