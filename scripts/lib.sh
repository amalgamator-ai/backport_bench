#!/usr/bin/env bash
# Shared helpers for the backport benchmark scripts.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AMALGAMATOR="${AMALGAMATOR:-$BENCH_DIR/../amalgamator}"
MODEL_REGISTRY="${MODEL_REGISTRY:-$BENCH_DIR/models/models.local.yaml}"
RESULTS="${RESULTS:-$BENCH_DIR/results}"
TOOLCHAINS="${TOOLCHAINS:-$HOME/toolchains}"
W8HW_ENV="${W8HW_ENV:-$HOME/w8hw-tools}"
UV_PYTHON_HOME="${UV_PYTHON_HOME:-$HOME/.local}"
export TOOLCHAINS W8HW_ENV UV_PYTHON_HOME

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

ref() { python3 "$BENCH_DIR/scripts/refs.py" get "$1" "$2"; }
ref_opt() { python3 "$BENCH_DIR/scripts/refs.py" get "$1" "$2" 2>/dev/null || true; }

case_names() {
  python3 - "$BENCH_DIR/refs/cases.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))["cases"]
for name in data:
    print(name)
PY
}

require_case() {
  [ -f "$BENCH_DIR/cases/$1/case.yaml" ] || die "unknown case '$1'"
}
