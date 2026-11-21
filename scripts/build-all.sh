#!/usr/bin/env bash
# Build every case pack (or the ones named on the command line).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [ "$#" -gt 0 ]; then cases=("$@"); else mapfile -t cases < <(case_names); fi
failed=()
for c in "${cases[@]}"; do
  if "$BENCH_DIR/scripts/build-case.sh" "$c" --force >/tmp/build-$c.log 2>&1; then
    printf '%-16s %s\n' "$c" "PASS"
  else
    printf '%-16s %s\n' "$c" "FAIL (see /tmp/build-$c.log)"
    failed+=("$c")
  fi
done
[ "${#failed[@]}" -eq 0 ] || { printf 'failed: %s\n' "${failed[*]}" >&2; exit 1; }
