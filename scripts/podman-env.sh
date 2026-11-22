#!/usr/bin/env bash
# Establish the podman command and environment used by this bench.
#
# Prefers a system podman. If none is on PATH, falls back to a rootless podman
# tree at $PODMAN_ROOT (default: $HOME/toolchains/podman-root), which needs a
# generated containers.conf, a private runtime dir and user policy files.
#
# Sourced by other scripts; sets PODMAN (array) and PODMAN_RUN_OPTS (array).
set -euo pipefail

: "${BENCH_DIR:?source scripts/lib.sh first}"

PODMAN_RUN_OPTS=(--security-opt label=disable --log-driver=passthrough)

if command -v podman >/dev/null 2>&1; then
  PODMAN=(podman)
  return 0 2>/dev/null || exit 0
fi

PODMAN_ROOT="${PODMAN_ROOT:-$HOME/toolchains/podman-root}"
[ -x "$PODMAN_ROOT/usr/bin/podman" ] \
  || die "no podman on PATH and no rootless podman at $PODMAN_ROOT (set PODMAN_ROOT)"

mkdir -p "$BENCH_DIR/.podman/"{xdg,static,tmp}
export PATH="/usr/bin:$PODMAN_ROOT/usr/bin:$PATH"
export LD_LIBRARY_PATH="$PODMAN_ROOT/usr/lib64:$PODMAN_ROOT/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_RUNTIME_DIR="$BENCH_DIR/.podman/xdg"
export TMPDIR="${TMPDIR:-/tmp}"

mkdir -p "$XDG_RUNTIME_DIR/libpod/tmp"

conf="$BENCH_DIR/.podman/containers.conf"
if [ ! -f "$conf" ]; then
  cat >"$conf" <<EOF
[engine]
helper_binaries_dir = ["$PODMAN_ROOT/usr/libexec/podman"]
runtime = "crun"
conmon_path = ["$PODMAN_ROOT/usr/bin/conmon"]
static_dir = "$BENCH_DIR/.podman/static"
tmp_dir = "$BENCH_DIR/.podman/tmp"
[network]
network_backend = "netavark"
EOF
fi
export CONTAINERS_CONF="$conf"

# Rootless pulls need a signature policy and registry config.
pol_dir="$HOME/.config/containers"
if [ ! -f "$pol_dir/policy.json" ]; then
  mkdir -p "$pol_dir"
  cp "$PODMAN_ROOT/etc/containers/policy.json" "$pol_dir/policy.json"
  cp "$PODMAN_ROOT/etc/containers/registries.conf" "$pol_dir/registries.conf"
fi

PODMAN=("$PODMAN_ROOT/usr/bin/podman")
