#!/usr/bin/env bash
# Verify runner invariants on the host and run each case's own prerequisite
# check inside that case's container image.
#
# Usage: check-prereqs.sh [case...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/podman-env.sh"

cases=()
if [ "$#" -gt 0 ]; then cases=("$@"); else mapfile -t cases < <(case_names); fi

fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf '%-24s ok\n' "$1"
  else printf '%-24s MISSING\n' "$1"; fail=1; fi
}

check "git" "command -v git"
check "python3" "command -v python3"
check "flock" "command -v flock"
check "podman" "\"${PODMAN[0]}\" info"
check "amalgamator venv" "test -x $AMALGAMATOR/.venv/bin/python"
check "model registry" "test -f $MODEL_REGISTRY"
check "free disk >20G" "test $(df -Pk / | awk 'NR==2{print $4}') -gt 20000000"

for c in "${cases[@]}"; do
  image="localhost/bench/$c:1"
  if ! "${PODMAN[@]}" image exists "$image" >/dev/null 2>&1; then
    printf '%-16s MISSING image %s (run build-images.sh)\n' "$c" "$image"
    fail=1
    continue
  fi
  if out="$("${PODMAN[@]}" run --rm --network=none \
        "${PODMAN_RUN_OPTS[@]}" \
        -v "$BENCH_DIR/cases/$c:/case:ro" \
        "$image" /case/check-prereqs.sh 2>&1)"; then
    printf '%-16s ok (%s)\n' "$c" "$(echo "$out" | tail -1)"
  else
    printf '%-16s FAILED\n%s\n' "$c" "$out" | sed 's/^/    /'
    fail=1
  fi
done

exit "$fail"
