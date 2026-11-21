#!/usr/bin/env bash
# Run one case in a network-isolated bubblewrap sandbox.
# Usage: run-case.sh <case> [--skip-verify]
set -euo pipefail
source "$(dirname "$0")/lib.sh"

case="${1:?usage: run-case.sh <case>}"
require_case "$case"
pack="$BENCH_DIR/cases/$case/repo.git"
[ -d "$pack" ] || die "[$case] pack missing; run scripts/build-case.sh $case"
[ -f "$AMALGAMATOR/.venv/bin/python" ] || die "amalgamator venv missing at $AMALGAMATOR/.venv"
[ -f "$MODEL_REGISTRY" ] || die "model registry missing: $MODEL_REGISTRY (copy models/models.example.yaml)"
command -v bwrap >/dev/null || die "bubblewrap (bwrap) is required"

"$BENCH_DIR/scripts/verify-no-leak.sh" "$case" >/dev/null \
  || die "[$case] pack failed the leak check"

ts="$(date +%Y%m%d_%H%M%S)"
run="$RESULTS/$case/$ts"
mkdir -p "$run"/{repo,work,cwd,home,tmp,tools} "$run/work/repo"
cp -a "$pack" "$run/work/repo/repo.git"
cp "$BENCH_DIR/scripts/forwarder.py" "$run/tools/"

lock="$RESULTS/.locks/$case.lock"
mkdir -p "$RESULTS/.locks"
exec 9>"$lock"
flock -n 9 || die "[$case] another run of this case is active (see $lock)"

python3 "$BENCH_DIR/scripts/refs.py" registry "$MODEL_REGISTRY" "$run/models.yaml"
endpoint="$(python3 "$BENCH_DIR/scripts/refs.py" host "$MODEL_REGISTRY")"
printf '127.0.0.1 %s\n' "$endpoint" > "$run/hosts"

cat > "$run/home/.gitconfig" <<'EOF'
[user]
	name = Backport Examples
	email = examples@example.invalid
[safe]
	directory = *
EOF

log "[$case] run dir: $run"
python3 "$BENCH_DIR/scripts/llm_proxy.py" --socket "$run/llm.sock" \
  --endpoint "$endpoint:443" --log "$run/proxy.log" &
proxy_pid=$!
trap 'kill "$proxy_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do [ -S "$run/llm.sock" ] && break; sleep 0.1; done
[ -S "$run/llm.sock" ] || die "[$case] proxy did not start"

start=$(date +%s)
set +e
bwrap --die-with-parent --new-session \
  --unshare-user --uid 0 --gid 0 \
  --unshare-net --unshare-pid --unshare-ipc --unshare-uts \
  --cap-add CAP_NET_ADMIN --cap-add CAP_NET_BIND_SERVICE \
  --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /sbin /sbin \
  --ro-bind /lib /lib --ro-bind /lib64 /lib64 \
  --ro-bind /etc /etc --ro-bind "$run/hosts" /etc/hosts \
  --ro-bind "$UV_PYTHON_HOME" "$UV_PYTHON_HOME" \
  --ro-bind "$TOOLCHAINS" "$TOOLCHAINS" \
  --ro-bind "$W8HW_ENV" "$W8HW_ENV" \
  --ro-bind "$AMALGAMATOR" /app \
  --ro-bind "$BENCH_DIR/cases/$case" /case \
  --ro-bind "$run/models.yaml" /run/models.yaml \
  --ro-bind "$run/tools" /tools \
  --ro-bind "$run/llm.sock" /run/llm.sock \
  --bind "$run" /work \
  --tmpfs /tmp --proc /proc --dev /dev \
  --setenv HOME /work/home \
  --setenv TMPDIR /work/tmp \
  --setenv PYTHONPATH /app \
  --setenv PYTHONDONTWRITEBYTECODE 1 \
  --setenv LITELLM_LOCAL_MODEL_COST_MAP True \
  --setenv GIT_CONFIG_GLOBAL /work/home/.gitconfig \
  --setenv GIT_CONFIG_SYSTEM /dev/null \
  --setenv BACKPORT_REPOS /work/work/repo \
  --setenv BACKPORT_WORK /work/work \
  --setenv TOOLCHAINS "$TOOLCHAINS" \
  --setenv W8HW_ENV "$W8HW_ENV" \
  --setenv UV_PYTHON_HOME "$UV_PYTHON_HOME" \
  --chdir /work/cwd \
  /bin/sh -c '
    set -e
    ip link set lo up
    python3 /tools/forwarder.py --listen 443 --unix /run/llm.sock &
    fwd=$!
    sleep 0.5
    set +e
    /app/.venv/bin/python -m auto_bug_fix.run_bug_fix \
        --models /run/models.yaml /case/case.yaml
    rc=$?
    kill "$fwd" 2>/dev/null || true
    exit "$rc"
  ' 2>&1 | tee "$run/run.log"
rc=${PIPESTATUS[0]}
set -e
end=$(date +%s)
echo "$((end - start))" > "$run/wall_s"

kill "$proxy_pid" 2>/dev/null || true
trap - EXIT

"$BENCH_DIR/scripts/audit-run.sh" "$run" "$case" || true
python3 - "$run" "$case" "$rc" <<'PY'
import json, sys
from pathlib import Path
run, case, rc = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
summary = None
runs = sorted((run / "cwd" / "runs").glob("*/summary.json"), key=lambda p: p.stat().st_mtime, reverse=True)
if runs:
    data = json.loads(runs[0].read_text())
    t = (data.get("targets") or [{}])[0]
    summary = {"outcome": t.get("outcome"), "duration_s": t.get("duration_s")}
tracker = None
for p in sorted(run.glob("cwd/runs/**/*_*.json"), key=lambda p: p.stat().st_mtime, reverse=True):
    try:
        d = json.loads(p.read_text())
    except Exception:
        continue
    if "phases" in d:
        tracker = {"input_tokens": d.get("total_input_tokens"),
                   "output_tokens": d.get("total_output_tokens")}
        break
result = {"case": case, "rc": rc, "wall_s": int((run / "wall_s").read_text().strip()),
          "summary": summary or {}, "tokens": tracker or {}}
(run / "result.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result))
PY

log "[$case] done (rc=$rc) -> $run"
exit "$rc"
