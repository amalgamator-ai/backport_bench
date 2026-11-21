#!/usr/bin/env bash
# Audit a finished run for attempts to reach the public fix or the network.
# Usage: audit-run.sh <run-dir> <case>
set -euo pipefail
source "$(dirname "$0")/lib.sh"

run="${1:?run dir}"; case="${2:?case}"
logf="$run/run.log"
out="$run/audit.json"
[ -f "$logf" ] || { echo '{"status":"SKIP","reason":"no log"}'; exit 0; }

upstream="$(ref "$case" upstream)"
host="${upstream#*://}"; host="${host%%/*}"
forbidden="$(python3 - "$BENCH_DIR/cases/$case/case.lock.json" <<'PY'
import json, sys
print(" ".join(s for s in json.load(open(sys.argv[1])).get("forbidden", []) if len(s) == 40))
PY
)"

python3 - "$logf" "$out" "$host" "$forbidden" <<'PY'
import json, re, sys
log_path, out_path, upstream_host, forbidden_raw = sys.argv[1:5]
forbidden = forbidden_raw.split()
remote_url = re.compile(r"https?://|\bgit@|\bssh://|\bgit://")
patterns = [
    (r"\bgit\s+fetch\b", "git fetch"),
    (r"\bgit\s+remote\b", "git remote"),
    (r"\bgit\s+ls-remote\b", "git ls-remote"),
    (r"\bgit\s+log\b[^\n]*--all", "git log --all"),
    (r"--remotes\b", "git --remotes"),
    (r"\bcurl\b", "curl"),
    (r"\bwget\b", "wget"),
]
# A clone is only evidence of reaching the network when its source is a URL.
# Local clones (e.g. of the case repository into /tmp for experiments) are fine.
host_patterns = []
if upstream_host:
    h = re.escape(upstream_host)
    host_patterns = [
        (rf"https?://{h}\b", "upstream host"),
        (rf"\bgit@{h}:", "upstream host"),
        (rf"(?<![\w./-]){h}[:/]", "upstream host"),
    ]
findings = []
with open(log_path, errors="replace") as fh:
    for lineno, line in enumerate(fh, 1):
        if "Tool:" not in line:
            continue
        for pat, name in patterns:
            if re.search(pat, line):
                findings.append({"line": lineno, "kind": name, "text": line.strip()[:300]})
        if "git clone" in line and remote_url.search(line):
            findings.append({"line": lineno, "kind": "git clone", "text": line.strip()[:300]})
        for pat, name in host_patterns:
            if re.search(pat, line):
                findings.append({"line": lineno, "kind": name, "text": line.strip()[:300]})
# Forbidden SHAs anywhere in the transcript mean the fix leaked into context.
with open(log_path, errors="replace") as fh:
    text = fh.read()
for sha in forbidden:
    if sha in text:
        findings.append({"kind": "forbidden sha", "sha": sha})
status = "FAIL" if findings else "PASS"
json.dump({"status": status, "findings": findings[:20]}, open(out_path, "w"), indent=2)
print(f"AUDIT {status}: {len(findings)} finding(s)")
PY
