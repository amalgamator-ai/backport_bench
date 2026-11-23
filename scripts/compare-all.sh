#!/usr/bin/env bash
# Compare the latest run with a candidate patch of every case (or those named).
# Usage: compare-all.sh [case...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

py="$AMALGAMATOR/.venv/bin/python"
[ -x "$py" ] || die "amalgamator venv missing: $py"

root="$RESULTS"
cases=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --results) root="$2"; shift 2 ;;
    *) cases+=("$1"); shift ;;
  esac
done
[ "${#cases[@]}" -gt 0 ] || mapfile -t cases < <(case_names)
for c in "${cases[@]}"; do
  run=""
  while read -r candidate; do
    run="${candidate%%/cwd/runs/*}"
    break
  done < <(ls -td "$root/$c"/*/cwd/runs/*/*/candidate.patch 2>/dev/null || true)
  if [ -z "$run" ]; then
    printf '%-16s no run with candidate.patch\n' "$c"
    continue
  fi
  if "$py" "$BENCH_DIR/scripts/judge.py" "$c" "$run" >/dev/null 2>"/tmp/judge-$c.log"; then
    printf '%-16s %s\n' "$c" "$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d['verdict'].get('verdict'), d['meta']['reference_kind'])" "$run/comparison.json")"
  else
    printf '%-16s FAIL (see /tmp/judge-%s.log)\n' "$c" "$c"
  fi
done
