#!/usr/bin/env bash
# Verify a case pack cannot leak the human fix or unrelated history.
# Usage: verify-no-leak.sh <case> [pack-path]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case="${1:?usage: verify-no-leak.sh <case> [pack]}"
pack="${2:-$BENCH_DIR/cases/$case/repo.git}"
[ -f "$BENCH_DIR/cases/$case/case.yaml" ] || die "[$case] unknown case"
[ -d "$pack" ] || die "[$case] missing pack: $pack"

fail() { printf 'LEAK-CHECK FAIL [%s]: %s\n' "$case" "$*" >&2; exit 1; }

bench="$(python3 "$BENCH_DIR/scripts/case_config.py" bench-json "$case")"

expected_refs="$(printf '%s' "$bench" | python3 -c '
import json, sys
bench = json.load(sys.stdin)
branches = [bench["source"]["branch"]]
targets = bench.get("targets") or [bench["target"]]
branches += [t["branch"] for t in targets]
print("\n".join(sorted(branches)))
')"
actual_refs="$(git --git-dir="$pack" for-each-ref --format='%(refname:short)' refs/heads | LC_ALL=C sort)"
[ "$expected_refs" = "$actual_refs" ] || fail "refs are '$actual_refs', expected '$expected_refs'"

# Every ref must sit exactly at the pinned public commit.
while read -r branch sha; do
  [ -n "$branch" ] || continue
  actual="$(git --git-dir="$pack" rev-parse "refs/heads/$branch")"
  [ "$actual" = "$sha" ] || fail "ref $branch is $actual, expected $sha"
done <<< "$(printf '%s' "$bench" | python3 -c '
import json, sys
bench = json.load(sys.stdin)
print(bench["source"]["branch"], bench["source"]["sha"])
for target in bench.get("targets") or [bench["target"]]:
    print(target["branch"], target["sha"])
')"

[ -z "$(git --git-dir="$pack" tag)" ] || fail "tags present"
[ -z "$(git --git-dir="$pack" remote)" ] || fail "remotes present"
[ -z "$(git --git-dir="$pack" for-each-ref refs/notes refs/replace 2>/dev/null)" ] || fail "notes/replace refs present"

# Unreachable objects (e.g. a pruned human fix) must be gone. fsck is by far
# the most expensive check, so cache its verdict keyed by the pack contents.
# Rebuilding a pack removes the directory, hence this stamp; fetching or
# writing into the pack changes the object count or refs and invalidates it.
pack_state="$( { git --git-dir="$pack" for-each-ref --format='%(refname) %(objectname)';
                 git --git-dir="$pack" count-objects -v; } 2>/dev/null | md5sum | cut -d' ' -f1 )"
fsck_stamp="$pack/.leak-fsck.ok"
if [ -f "$fsck_stamp" ] && [ "$(cat "$fsck_stamp")" = "$pack_state" ]; then
  :
else
  unreachable="$(git --git-dir="$pack" fsck --unreachable --no-reflogs 2>/dev/null || true)"
  [ -z "$unreachable" ] || fail "unreachable objects: $(echo "$unreachable" | head -3)"
  printf '%s\n' "$pack_state" > "$fsck_stamp"
fi

# Forbidden commits (human backports) must not exist at all. The upstream fix
# itself is an input, so an entry equal to it is skipped. Entries may be
# abbreviated; git resolves them.
fix_sha="$(printf '%s' "$bench" | python3 -c '
import json, sys
print((json.load(sys.stdin).get("fix") or {}).get("sha") or "")
')"
forbidden="$(printf '%s' "$bench" | python3 -c '
import json, sys
print("\n".join((json.load(sys.stdin).get("forbidden") or [])))
')"
while read -r sha; do
  [ -n "$sha" ] || continue
  [ "$sha" = "$fix_sha" ] && continue
  if git --git-dir="$pack" cat-file -e "$sha^{commit}" 2>/dev/null; then
    fail "forbidden human-fix commit present: $sha"
  fi
done <<< "$forbidden"

# The fix must not already be an ancestor of the target branch.
target_branch="$(printf '%s' "$bench" | python3 -c '
import json, sys
bench = json.load(sys.stdin)
print((bench.get("targets") or [bench["target"]])[-1]["branch"])
')"
if [ -n "$fix_sha" ]; then
  if git --git-dir="$pack" merge-base --is-ancestor "$fix_sha" "refs/heads/$target_branch"; then
    fail "fix $fix_sha is already in $target_branch"
  fi
fi

target_tree="$(git --git-dir="$pack" rev-parse "refs/heads/$target_branch^{tree}")"
printf 'LEAK-CHECK PASS [%s]: refs=%s forbidden=%s target_tree=%s\n' "$case" \
  "$(echo "$expected_refs" | tr '\n' ',')" \
  "$(echo "$forbidden" | grep -c . || true)" \
  "${target_tree:0:12}"
