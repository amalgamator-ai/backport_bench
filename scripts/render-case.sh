#!/usr/bin/env bash
# Render cases/<case>/run/, the directory mounted into the run container.
# Usage: render-case.sh [case...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [ "$#" -gt 0 ]; then cases=("$@"); else mapfile -t cases < <(case_names); fi
for c in "${cases[@]}"; do
  require_case "$c"
  python3 "$BENCH_DIR/scripts/case_config.py" render "$c" >/dev/null
done
