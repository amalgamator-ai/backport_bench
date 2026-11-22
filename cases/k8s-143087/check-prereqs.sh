#!/usr/bin/env bash
# Case prerequisites, executed inside this case's container image.
set -euo pipefail
fail() { echo "missing: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1"; }
need go; need git; need gcc; need make
[ -d /opt/gomodcache/golang.org/x ] || fail gomodcache
echo "ok k8s-143087"
