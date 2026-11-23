#!/usr/bin/env python3
"""Compare an AI-generated backport against the recorded human backport.

Runs on the host after the container exits: the human backport never enters a
run container (only ``cases/<case>/run/`` is mounted).

Inputs per case:
  cases/<case>/human/human.patch   recorded human backport (record-human.sh)
  <run>/cwd/runs/*/candidate.patch  the AI result
  cases/<case>/repo.git             target-cut code context for shared files

For cases with no human backport (bench.human.mode=none) the reference is the
upstream fix commit taken from the pack, labelled ``reference: fix``.

Writes <run>/comparison.json and <run>/comparison.md, and appends one row per
case to results/comparison.csv. The model is resolved from the registry
(default profile, or JUDGE_PROFILE / --profile).

Usage:
  judge.py <case> <run-dir> [--models PATH] [--profile ID] [--max-chars N]
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

import case_config as cc

ROOT = Path(__file__).resolve().parent.parent
AMALGAMATOR = Path(os.environ.get("AMALGAMATOR", ROOT.parent / "amalgamator"))

SYSTEM = (
    "You are an expert security backport reviewer. You compare an AI-generated "
    "backport with a reference backport of the same upstream fix. Judge whether "
    "the AI change fixes the same bug in the same way, whether it is complete, "
    "and whether it introduces risk. Reason from the diffs and the target code, "
    "not from the test outcome alone; passing tests do not prove equivalence. "
    "Cite files and line context for every claim. Answer with JSON only."
)

SCHEMA = """{
  "verdict": "equivalent | mostly_equivalent | partial | different | wrong",
  "confidence": 0.0,
  "summary": "2-4 sentences",
  "same_bug_fixed": true,
  "mechanism": "how each change addresses the bug",
  "security_property_preserved": "yes | no | unknown",
  "completeness": {"missing_changes": ["..."], "extra_changes": ["..."]},
  "test_coverage": {"reference": "...", "ai": "...", "assessment": "..."},
  "risks": ["..."],
  "files": [{"path": "...", "reference": "...", "ai": "...", "assessment": "..."}],
  "evidence": ["path: context -> claim"]
}"""


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", f"--git-dir={repo}", *args],
        capture_output=True,
        text=True,
        errors="replace",
        check=True,
    ).stdout


def patch_blocks(text: str) -> dict[str, str]:
    blocks: dict[str, list[str]] = {}
    current = None
    for line in text.splitlines(keepends=True):
        if line.startswith("diff --git "):
            match = re.search(r" b/(\S+)", line)
            current = match.group(1) if match else line.strip()
            blocks[current] = []
        elif current is not None:
            blocks[current].append(line)
    return {path: "".join(lines) for path, lines in blocks.items()}


def patch_stat(text: str) -> str:
    files = patch_blocks(text)
    rows = []
    for path, block in files.items():
        plus = sum(1 for line in block.splitlines() if line.startswith("+") and not line.startswith("+++"))
        minus = sum(1 for line in block.splitlines() if line.startswith("-") and not line.startswith("---"))
        rows.append(f"{path} (+{plus}/-{minus})")
    return "\n".join(rows)


def find_ai_patch(run: Path) -> Path:
    patches = sorted(
        run.glob("cwd/runs/**/candidate.patch"), key=lambda p: p.stat().st_mtime
    )
    if not patches:
        raise SystemExit(f"no candidate.patch under {run}")
    return patches[-1]


def find_summary(run: Path) -> dict:
    summaries = sorted(
        run.glob("cwd/runs/**/summary.json"), key=lambda p: p.stat().st_mtime
    )
    if not summaries:
        return {}
    data = json.loads(summaries[-1].read_text())
    targets = data.get("targets") or [{}]
    return targets[0]


def reference_patch(case: str, bench: dict) -> tuple[str, str, str]:
    """Return (patch text, kind, description)."""
    human = ROOT / "cases" / case / "human" / "human.patch"
    meta = ROOT / "cases" / case / "human" / "human.json"
    if human.is_file():
        info = json.loads(meta.read_text()) if meta.is_file() else {}
        commits = "; ".join(
            f"{c['sha'][:12]} {c.get('subject', '')}".strip()
            for c in info.get("commits") or []
        ) or "recorded"
        return human.read_text(), "human", f"human backport: {commits}"
    pack = ROOT / "cases" / case / "repo.git"
    fix = (bench.get("fix") or {}).get("sha")
    if fix and pack.is_dir():
        text = git(pack, "diff", f"{fix}^1", fix)
        return text, "fix", f"upstream fix {fix[:12]} (no human backport exists)"
    raise SystemExit(f"{case}: no human backport and no fix patch available")


def select_blocks(text: str, wanted: set[str] | None, max_chars: int) -> str:
    """Diff blocks for the wanted files first, then the rest, under a budget."""
    blocks = patch_blocks(text)
    if wanted is None:
        order = list(blocks)
    else:
        order = [p for p in blocks if p in wanted]
        order += [p for p in blocks if p not in wanted]
    budget = max_chars
    parts, included = [], []
    for path in order:
        if budget <= 0:
            break
        block = blocks[path]
        if len(block) <= budget:
            parts.append(block)
            budget -= len(block)
        else:
            parts.append(block[:budget] + "\n[... truncated ...]\n")
            budget = 0
        included.append(path)
    body = "\n".join(parts) or "(no diff blocks)"
    omitted = [p for p in blocks if p not in included]
    if omitted:
        body += (
            f"\n\nFiles not shown for size ({len(omitted)}): "
            + ", ".join(omitted[:80])
            + (" ..." if len(omitted) > 80 else "")
        )
    return body


def code_context(pack: Path, cut: str, ai_text: str, limit: int = 12000) -> str:
    chunks = []
    for path in sorted(patch_blocks(ai_text)):
        try:
            content = git(pack, "show", f"{cut}:{path}")
        except subprocess.CalledProcessError:
            chunks.append(f"--- {path}: absent at the target cut")
            continue
        chunks.append(f"--- {path} at target cut\n{content[:limit]}")
        if sum(len(c) for c in chunks) > limit * 3:
            break
    return "\n\n".join(chunks)


def build_prompt(case: str, run: Path, bench: dict, pipeline: dict) -> dict:
    ai_path = find_ai_patch(run)
    ai_text = ai_path.read_text(errors="replace")
    ref_text, kind, ref_desc = reference_patch(case, bench)
    ai_files = set(patch_blocks(ai_text))
    ref_body = select_blocks(ref_text, ai_files, max_chars=60_000)
    ref_stats = patch_stat(ref_text)
    ai_body = select_blocks(ai_text, set(patch_blocks(ref_text)), max_chars=120_000)
    summary = find_summary(run)
    pack = ROOT / "cases" / case / "repo.git"
    cut = (bench.get("targets") or [bench["target"]])[-1]["sha"]
    context = code_context(pack, cut, ai_text)
    user = f"""# Case {case}

## Bug
{pipeline.get('bug_description', '').strip()[:4000]}

## Reference ({ref_desc})
Reference size: {len(ref_text)} bytes.
Reference file stat:
{ref_stats}

Reference diff for files the AI patch also touches:
<reference>
{ref_body}
</reference>

## AI backport ({ai_path.name})
Run outcome: {summary.get('outcome')}, duration={summary.get('duration_s')}s
AI file stat:
{patch_stat(ai_text)}

AI diff:
<ai>
{ai_body}
</ai>

## Target code at the cut (unchanged upstream sources the AI started from)
<context>
{context}
</context>

Compare the AI backport with the reference. If the reference is the upstream
fix (no human backport exists), judge whether the AI port preserves its
behaviour on the target branch. Answer with JSON matching this schema:
{SCHEMA}"""
    return {
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user},
        ],
        "ai_path": ai_path,
        "reference_kind": kind,
        "reference_desc": ref_desc,
        "summary": summary,
    }


def parse_json(text: str) -> dict:
    text = text.strip()
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text, flags=re.S)
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < 0:
        raise ValueError("no JSON object in model output")
    return json.loads(text[start : end + 1])


def render_markdown(case: str, verdict: dict, meta: dict) -> str:
    files = verdict.get("files") or []
    rows = "\n".join(
        f"| `{f.get('path','')}` | {f.get('reference','')} | {f.get('ai','')} | {f.get('assessment','')} |"
        for f in files
    )
    missing = "\n".join(f"- {x}" for x in (verdict.get("completeness") or {}).get("missing_changes") or []) or "- none"
    extra = "\n".join(f"- {x}" for x in (verdict.get("completeness") or {}).get("extra_changes") or []) or "- none"
    risks = "\n".join(f"- {x}" for x in verdict.get("risks") or []) or "- none"
    evidence = "\n".join(f"- {x}" for x in verdict.get("evidence") or []) or "- none"
    tests = verdict.get("test_coverage") or {}
    return f"""# AI vs {meta['reference_kind']} comparison — {case}

- **Verdict:** {verdict.get('verdict')} (confidence {verdict.get('confidence')})
- **Reference:** {meta['reference_desc']}
- **AI run:** outcome={meta['summary'].get('outcome')}, duration={meta['summary'].get('duration_s')}s
- **Judge model:** {meta['model']}

## Summary
{verdict.get('summary')}

## Mechanism
{verdict.get('mechanism')}

Same bug fixed: **{verdict.get('same_bug_fixed')}** · Security property preserved: **{verdict.get('security_property_preserved')}**

## Missing changes
{missing}

## Extra changes
{extra}

## Tests
- reference: {tests.get('reference','')}
- ai: {tests.get('ai','')}
- assessment: {tests.get('assessment','')}

## Risks
{risks}

## Files
| path | reference | AI | assessment |
|---|---|---|---|
{rows}

## Evidence
{evidence}
"""


def main(argv: list[str]) -> None:
    case = argv[0]
    run = Path(argv[1]).resolve()
    models = ROOT / "models" / "models.local.yaml"
    profile_id = os.environ.get("JUDGE_PROFILE")
    if "--models" in argv:
        models = Path(argv[argv.index("--models") + 1])
    if "--profile" in argv:
        profile_id = argv[argv.index("--profile") + 1]
    data = cc.load(case)
    bench, pipeline = data["bench"], data["pipeline"]
    prompt = build_prompt(case, run, bench, pipeline)

    sys.path.insert(0, str(AMALGAMATOR))
    from common.llm_client import completion  # noqa: E402
    from common.model_registry import load_registry  # noqa: E402

    registry = load_registry(models)
    profile = registry.resolve(profile_id)
    result = completion(profile.model, prompt["messages"], profile=profile, max_tokens=8192)
    try:
        verdict = parse_json(result.text)
    except (ValueError, json.JSONDecodeError) as exc:
        (run / "comparison.raw.txt").write_text(result.text)
        raise SystemExit(f"{case}: judge output was not JSON ({exc}); raw saved") from exc

    meta = {
        "reference_kind": prompt["reference_kind"],
        "reference_desc": prompt["reference_desc"],
        "summary": prompt["summary"],
        "model": profile.model,
        "generated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "input_tokens": result.input_tokens,
        "output_tokens": result.output_tokens,
    }
    (run / "comparison.json").write_text(
        json.dumps({"case": case, "meta": meta, "verdict": verdict}, indent=2) + "\n"
    )
    (run / "comparison.md").write_text(render_markdown(case, verdict, meta))

    # <results-root>/<case>/<timestamp> -> <results-root>/comparison.csv
    results_root = run.resolve().parents[1]
    csv_path = results_root / "comparison.csv"
    csv_path.parent.mkdir(exist_ok=True)
    header = "case,verdict,confidence,reference,judge_model,generated,run"
    rows = []
    if csv_path.exists():
        lines = csv_path.read_text().splitlines()
        if lines and lines[0].startswith("case,"):
            rows = [line for line in lines[1:] if line and not line.startswith(case + ",")]
    row = (
        f"{case},{verdict.get('verdict')},{verdict.get('confidence')},"
        f"{prompt['reference_kind']},{profile.model},{meta['generated']},{run}"
    )
    csv_path.write_text("\n".join([header, *rows, row]) + "\n")
    print(
        f"{case}: {verdict.get('verdict')} (confidence {verdict.get('confidence')}) "
        f"-> {run / 'comparison.md'}"
    )


if __name__ == "__main__":
    main(sys.argv[1:])
