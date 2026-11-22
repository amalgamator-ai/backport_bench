#!/usr/bin/env bash
# Case prerequisites, executed inside this case's container image.
set -euo pipefail
fail() { echo "missing: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1"; }
need gcc; need make; need bison; need gawk; need perl; need python3; need makeinfo
echo "ok glibc"
