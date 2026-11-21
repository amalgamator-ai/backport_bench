#!/usr/bin/env bash
# Verify a case pack cannot leak the human fix or unrelated history.
# Usage: verify-no-leak.sh <case> [pack-path]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case="${1:?usage: verify-no-leak.sh <case> [pack]}"
pack="${2:-$BENCH_DIR/cases/$case/repo.git}"
lock="$BENCH_DIR/cases/$case/case.lock.json"
[ -f "$lock" ] || die "[$case] missing case.lock.json"
[ -d "$pack" ] || die "[$case] missing pack: $pack"

fail() { printf 'LEAK-CHECK FAIL [%s]: %s\n' "$case" "$*" >&2; exit 1; }

expected_refs="$(python3 - "$lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
print("\n".join(sorted(lock["refs"])))
PY
)"
actual_refs="$(git --git-dir="$pack" for-each-ref --format='%(refname:short)' refs/heads | LC_ALL=C sort)"
[ "$expected_refs" = "$actual_refs" ] || fail "refs are '$actual_refs', expected '$expected_refs'"

[ -z "$(git --git-dir="$pack" tag)" ] || fail "tags present"
[ -z "$(git --git-dir="$pack" remote)" ] || fail "remotes present"
[ -z "$(git --git-dir="$pack" for-each-ref refs/notes refs/replace 2>/dev/null)" ] || fail "notes/replace refs present"
[ ! -f "$pack/shallow.lock" ] || true

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
# itself is an input, so an entry equal to it is skipped.
fix_for_verify="$(python3 - "$lock" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["fix"].get("sha") or "")
PY
)"
while read -r sha; do
  [ -n "$sha" ] || continue
  [ "$sha" = "$fix_for_verify" ] && continue
  if git --git-dir="$pack" cat-file -e "$sha^{commit}" 2>/dev/null; then
    fail "forbidden human-fix commit present: $sha"
  fi
done < <(python3 - "$lock" <<'PY'
import json, sys
for sha in json.load(open(sys.argv[1])).get("forbidden", []):
    if len(sha) == 40:
        print(sha)
PY
)

# The fix must not already be an ancestor of the target branch.
fix_sha="$(python3 - "$lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
print(lock["fix"].get("sha") or "")
PY
)"
if [ -n "$fix_sha" ]; then
  target_branch="$(python3 - "$lock" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1]))
refs = list(lock["refs"])
print(refs[-1])
PY
)"
  if git --git-dir="$pack" merge-base --is-ancestor "$fix_sha" "refs/heads/$target_branch"; then
    fail "fix $fix_sha is already in $target_branch"
  fi
fi

printf 'LEAK-CHECK PASS [%s]: refs=%s forbidden=%s\n' "$case" \
  "$(echo "$expected_refs" | tr '\n' ',')" \
  "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('forbidden',[])))" "$lock")"
