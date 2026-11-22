#!/usr/bin/env bash
# Build one sanitized case pack from public repositories.
# Usage: build-case.sh <case> [--force|--verify]
#
#   --force   rebuild the pack even if it exists
#   --verify  keep the existing pack; run discovery, the leak check and the
#             render step only
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case="${1:?usage: build-case.sh <case> [--force|--verify]}"
mode=build
force=0
for arg in "${@:2}"; do
  case "$arg" in
    --force) force=1 ;;
    --verify) mode=verify ;;
    *) die "unknown argument: $arg" ;;
  esac
done
require_case "$case"

upstream="$(ref "$case" upstream)"
s_br="$(ref "$case" source.branch)"; s_sha="$(ref "$case" source.sha)"
t_br="$(ref "$case" target.branch)"; t_sha="$(ref "$case" target.sha)"
t_up_br="$(ref_opt "$case" target.upstream_branch)"; [ -n "$t_up_br" ] || t_up_br="$t_br"
fix_kind="$(ref "$case" fix.kind)"
fix_sha="$(ref_opt "$case" fix.sha)"
fix_ref="$(ref_opt "$case" fix.upstream_ref)"

pack="$BENCH_DIR/cases/$case/repo.git"
if [ "$mode" = "verify" ]; then
  [ -d "$pack" ] || die "[$case] no pack to verify: $pack"
elif [ -e "$pack" ] && [ "$force" -ne 1 ]; then
  die "pack already exists: $pack (pass --force to rebuild)"
else
  rm -rf "$pack"
  git init -q --bare "$pack"

  cache_dir="$BENCH_DIR/cache"
  mkdir -p "$cache_dir"
  slug="$(basename "$upstream" .git)"
  cache="$cache_dir/$slug.git"
  if [ ! -d "$cache" ]; then
    log "[$case] caching $upstream (one-time full clone)"
    tmp_cache="$cache_dir/.tmp-$slug-$$"
    rm -rf "$tmp_cache"; mkdir -p "$tmp_cache"
    git clone -q --bare "$upstream" "$tmp_cache/repo.git" || die "[$case] cannot clone $upstream"
    mv "$tmp_cache/repo.git" "$cache"
    rm -rf "$tmp_cache"
  fi

  fetched=0
  for attempt in 1 2 3; do
    rm -rf "$pack"; git init -q --bare "$pack"
    log "[$case] populating from cache: $s_br@${s_sha:0:12}, $t_br@${t_sha:0:12}"
    if git --git-dir="$pack" fetch -q --no-tags "$cache" \
         "$s_sha:refs/heads/$s_br" "$t_sha:refs/heads/$t_br"; then
      fetched=1; break
    fi
    log "[$case] local fetch failed (attempt $attempt), retrying"
    sleep 2
  done
  [ "$fetched" -eq 1 ] || die "[$case] cannot populate pack from cache"

  # The pipeline needs a real merge-base between source and target.
  git --git-dir="$pack" merge-base "refs/heads/$s_br" "refs/heads/$t_br" >/dev/null \
    || die "[$case] source and target share no history"

  # Drop the fetch remote and every trace of it; the pack must be self-contained.
  git --git-dir="$pack" remote remove origin 2>/dev/null || true
  git --git-dir="$pack" reflog expire --all --expire=now
  git --git-dir="$pack" gc --prune=now -q
fi

# Best-effort discovery of public human backports: same subject on the target
# branch's current head. A hit that is not recorded in bench.forbidden fails
# the build, so the guard stays explicit instead of silently generated.
fix_subject=""
if [ "$fix_kind" = "commit" ]; then
  fix_subject="$(git --git-dir="$pack" log -1 --format=%s "$fix_sha" 2>/dev/null || true)"
elif [ -n "$fix_ref" ]; then
  scratch="$(mktemp -d)"; git init -q "$scratch"
  if git -C "$scratch" fetch -q --no-tags --depth=1 "$upstream" "$fix_ref" 2>/dev/null; then
    fix_subject="$(git -C "$scratch" log -1 --format=%s FETCH_HEAD)"
  fi
  rm -rf "$scratch"
fi

discovered=()
if [ -n "$fix_subject" ]; then
  scratch="$(mktemp -d)"; git init -q "$scratch"
  if git -C "$scratch" fetch -q --no-tags --depth=100 --filter=blob:none \
        "$upstream" "refs/heads/$t_up_br" 2>/dev/null; then
    while read -r sha subject; do
      [ -n "$sha" ] || continue
      if [ "$subject" = "$fix_subject" ]; then discovered+=("$sha"); fi
    done < <(git -C "$scratch" log --format='%H %s' FETCH_HEAD 2>/dev/null)
  fi
  rm -rf "$scratch"
fi

bench_json="$(python3 "$BENCH_DIR/scripts/case_config.py" bench-json "$case")"
python3 - "$case" "$pack" "$bench_json" "${discovered[@]}" <<'PY'
import json, subprocess, sys
case, pack, bench_raw = sys.argv[1:4]
bench = json.loads(bench_raw)
discovered = [s for s in sys.argv[4:] if s]
fix_sha = (bench.get("fix") or {}).get("sha") or ""
known = [s for s in bench.get("forbidden") or [] if s != fix_sha]
short = [s for s in bench.get("forbidden") or [] if len(s) != 40]
if short:
    raise SystemExit(f"{case}: bench.forbidden entries must be full SHAs: {short}")
unrecorded = [
    s for s in discovered
    if s != fix_sha and not any(s.startswith(k) or k.startswith(s) for k in known)
]
if unrecorded:
    raise SystemExit(
        f"{case}: discovered human backport(s) not recorded in bench.forbidden: "
        + ", ".join(sorted(unrecorded))
    )
target = (bench.get("targets") or [bench["target"]])[-1]["branch"]
tree = subprocess.run(
    ["git", "--git-dir", pack, "rev-parse", f"refs/heads/{target}^{{tree}}"],
    capture_output=True, text=True, check=True,
).stdout.strip()
print(f"{case}: target_tree={tree}")
PY

"$BENCH_DIR/scripts/verify-no-leak.sh" "$case"
python3 "$BENCH_DIR/scripts/case_config.py" render "$case" >/dev/null
log "[$case] pack ready: $pack"
