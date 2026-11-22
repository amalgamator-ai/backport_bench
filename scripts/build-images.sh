#!/usr/bin/env bash
# Build the per-case container images.
#
# Two shared bases are built once: bench-tools (Fedora: gcc/make/autotools/
# bison/flex/cmake/tcl/php build deps) and bench-go (golang:1.25 + the x/crypto
# module cache). Every case gets its own image tag bench/<case>:1 pointing at
# one of those bases; case/check-prereqs.sh runs inside it.
#
# Usage: build-images.sh [--force] [case...]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/podman-env.sh"

force=0
cases=()
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) cases+=("$arg") ;;
  esac
done
[ "${#cases[@]}" -gt 0 ] || mapfile -t cases < <(case_names)

TOOLS_IMAGE="localhost/bench-tools:1"
GO_IMAGE="localhost/bench-go:1"
FEDORA_IMAGE="quay.io/fedora/fedora:44"
GOLANG_IMAGE="docker.io/library/golang:1.25"

go_cases=" runc containerd k8s-2270 k8s-143087 golang-crypto "

have_image() { "${PODMAN[@]}" image exists "$1" 2>/dev/null; }

ensure_base() {
  local image="$1"
  if ! have_image "$image"; then
    log "pulling $image"
    "${PODMAN[@]}" pull "$image" >/dev/null
  fi
}

build_tools() {
  if [ "$force" = 0 ] && have_image "$TOOLS_IMAGE"; then
    return
  fi
  ensure_base "$FEDORA_IMAGE"
  local cid="bench-build-tools-$$"
  log "building $TOOLS_IMAGE (dnf install, network required)"
  "${PODMAN[@]}" run --name "$cid" --network=host \
    --security-opt label=disable --log-driver=passthrough "$FEDORA_IMAGE" \
    sh -c 'dnf -y install gcc gcc-c++ make git python3 perl autoconf automake \
      libtool bison flex cmake tcl findutils diffutils patch which tar gzip xz \
      bzip2 sed gawk grep coreutils procps-ng iproute iputils texinfo re2c \
      pkgconf popt-devel ncurses-devel readline-devel zlib-devel \
      libxml2-devel sqlite-devel oniguruma-devel gettext-devel openssl-devel \
      && dnf clean all' >/dev/null
  if [ -d "$TOOLCHAINS/tcl" ]; then
    "${PODMAN[@]}" cp "$TOOLCHAINS/tcl" "$cid:/opt/tcl"
  fi
  "${PODMAN[@]}" commit -q "$cid" "$TOOLS_IMAGE"
  "${PODMAN[@]}" rm -f "$cid" >/dev/null
}

build_go() {
  if [ "$force" = 0 ] && have_image "$GO_IMAGE"; then
    return
  fi
  ensure_base "$GOLANG_IMAGE"
  local cid="bench-build-go-$$"
  log "building $GO_IMAGE from $GOLANG_IMAGE"
  "${PODMAN[@]}" create --name "$cid" --security-opt label=disable \
    "$GOLANG_IMAGE" true >/dev/null
  if [ -d "$TOOLCHAINS/gomodcache" ]; then
    "${PODMAN[@]}" cp "$TOOLCHAINS/gomodcache" "$cid:/opt/gomodcache"
  fi
  "${PODMAN[@]}" commit -q "$cid" "$GO_IMAGE"
  "${PODMAN[@]}" rm -f "$cid" >/dev/null
}

build_tools
build_go

declare -A built=()
for c in "${cases[@]}"; do
  if [[ "$go_cases" == *" $c "* ]]; then base="$GO_IMAGE"; else base="$TOOLS_IMAGE"; fi
  case_image="localhost/bench/$c:1"
  "${PODMAN[@]}" tag "$base" "$case_image"
  built["$c"]="$case_image"
  printf '%-16s %s\n' "$c" "$case_image"
done

lock="$BENCH_DIR/images.lock.json"
{
  printf '{\n  "images": {\n'
  first=1
  for c in "${!built[@]}"; do
    id="$("${PODMAN[@]}" image inspect --format '{{.Id}}' "${built[$c]}")"
    [ "$first" -eq 1 ] || printf ',\n'
    printf '    "%s": {"image": "%s", "id": "%s"}' "$c" "${built[$c]}" "$id"
    first=0
  done
  printf '\n  }\n}\n'
} >"$lock"
log "wrote $lock"
