#!/usr/bin/env bash
# Case prerequisites, executed inside this case's container image.
set -euo pipefail
fail() { echo "missing: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1"; }
need gcc; need make
[ -x /opt/tcl/bin/tclsh ] || fail tclsh
printf 'puts [info patchlevel]\n' | LD_LIBRARY_PATH=/opt/tcl/lib /opt/tcl/bin/tclsh \
  | grep -q '^8\.6' || fail 'tcl 8.6'
echo "ok valkey"
