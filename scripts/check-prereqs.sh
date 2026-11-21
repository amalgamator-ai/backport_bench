#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then printf '%-28s ok\n' "$1"; else printf '%-28s MISSING\n' "$1"; fail=1; fi; }
check "git" "command -v git"
check "python3" "command -v python3"
check "bubblewrap" "command -v bwrap"
check "flock" "command -v flock"
check "amalgamator venv" "test -x $AMALGAMATOR/.venv/bin/python"
check "model registry" "test -f $MODEL_REGISTRY"
check "go toolchain" "test -x $TOOLCHAINS/go/bin/go"
check "go module cache" "test -d $TOOLCHAINS/gomodcache/golang.org/x"
check "tcl for valkey" "test -x $TOOLCHAINS/tcl/bin/tclsh"
check "build env" "test -x $W8HW_ENV/env/bin/autoconf"
check "free disk >20G" "test $(df -Pk / | awk 'NR==2{print $4}') -gt 20000000"
check "bwrap netns" "bwrap --unshare-user --uid 0 --gid 0 --unshare-net --cap-add CAP_NET_ADMIN --cap-add CAP_NET_BIND_SERVICE --ro-bind / / --dev /dev --proc /proc /bin/sh -c 'ip link set lo up'"
exit "$fail"
