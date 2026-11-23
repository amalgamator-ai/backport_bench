#!/usr/bin/env python3
"""Record the human backport of a case as a patch that is never mounted.

The human backport is derived from the local ``cache/`` mirror (a full clone of
the upstream repository), written to ``cases/<case>/human/``:

  human.patch   one ``git diff`` per selected backport commit, with a small
                header naming the commit
  human.json    provenance: mode, base cut, commits, files, hashes, whether
                the patch applies cleanly to the target cut

Modes (bench.human.mode):

  commits      human.commits (else bench.forbidden) lists the backport
               commits; the ones merged into the upstream target branch are
               used
  none         no human backport exists; nothing is written

The directory is never mounted into a run container: only
``cases/<case>/run/`` is (see scripts/run-case.sh).

Usage:
  record_human.py <case> [--force] [--check]
  record_human.py all
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import case_config as cc

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "cache"


def git(repo: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", f"--git-dir={repo}", *args], capture_output=True, text=True, check=check
    )


def cache_repo(case: str) -> Path:
    bench = cc.load(case)["bench"]
    slug = Path(bench["upstream"]).name.removesuffix(".git")
    return CACHE / f"{slug}.git"


def upstream_branch(bench: dict) -> str:
    target = (bench.get("targets") or [bench["target"]])[-1]
    return target.get("upstream_branch") or target["branch"]


def commit_meta(repo: str, sha: str) -> dict:
    out = git(repo, "log", "-1", "--format=%H%x00%ad%x00%s", "--date=short", sha).stdout
    full, date, subject = out.strip().split("\x00", 2)
    return {"sha": full, "date": date, "subject": subject}


def commit_diff(repo: str, sha: str, paths: list[str] | None = None) -> str:
    """Diff of a single commit against its first parent."""
    args = ["diff", f"{sha}^1", sha]
    if paths:
        args += ["--", *paths]
    return git(repo, *args).stdout


def select_commits(case: str, bench: dict, repo: str) -> list[str]:
    """Backport commits recorded in human.commits (else bench.forbidden).

    Only commits merged into the upstream target branch are kept, so a
    forbidden entry that belongs to another release line is ignored.
    """
    human = bench.get("human") or {}
    recorded = human.get("commits") or bench.get("forbidden") or []
    branch = f"refs/heads/{upstream_branch(bench)}"
    selected = []
    for sha in recorded:
        if git(repo, "merge-base", "--is-ancestor", sha, branch, check=False).returncode == 0:
            selected.append(sha)
    return selected


def materialize_cut(repo: str, cut: str, paths: list[str], workdir: Path) -> None:
    """Write the cut version of the given paths so git apply --check can run."""
    for path in paths:
        proc = git(repo, "show", f"{cut}:{path}", check=False)
        target = workdir / path
        if proc.returncode != 0:
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(proc.stdout.encode())


def applies_to_cut(repo: str, cut: str, patch: Path) -> bool | None:
    paths = sorted(
        {
            line.split(" b/", 1)[1].strip()
            for line in patch.read_text(errors="replace").splitlines()
            if line.startswith("diff --git ")
        }
    )
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        subprocess.run(["git", "init", "-q"], cwd=work, check=True)
        materialize_cut(repo, cut, paths, work)
        proc = subprocess.run(
            ["git", "apply", "--check", str(patch.resolve())],
            cwd=work,
            capture_output=True,
            text=True,
        )
    return proc.returncode == 0


def record(case: str, force: bool, check: bool) -> None:
    bench = cc.load(case)["bench"]
    human = bench.get("human") or {"mode": "none"}
    mode = human["mode"]
    out_dir = ROOT / "cases" / case / "human"
    if mode == "none":
        if out_dir.exists():
            for path in out_dir.iterdir():
                path.unlink()
            out_dir.rmdir()
        print(f"{case}: no human backport (mode=none)")
        return

    repo = cache_repo(case)
    if not repo.is_dir():
        raise SystemExit(f"{case}: cache mirror missing: {repo}")
    patch_path = out_dir / "human.patch"
    if patch_path.exists() and not force:
        raise SystemExit(f"{case}: {patch_path} exists (pass --force)")

    commits = select_commits(case, bench, repo)
    if not commits:
        raise SystemExit(f"{case}: mode={mode} but no backport commits were found")
    paths = None

    chunks = []
    metas = []
    for sha in commits:
        meta = commit_meta(repo, sha)
        diff = commit_diff(repo, sha, paths)
        if not diff.strip():
            continue
        metas.append(meta)
        chunks.append(
            f"# human backport {meta['sha']} ({meta['date']}) {meta['subject']}\n{diff}"
        )
    if not chunks:
        raise SystemExit(f"{case}: selected commits produced no diff")

    out_dir.mkdir(exist_ok=True)
    patch_path.write_text("\n".join(chunks))
    patch_text = patch_path.read_text()
    added = "\n".join(
        line[1:] for line in patch_text.splitlines() if line.startswith("+")
    )
    record = {
        "case": case,
        "mode": mode,
        "base": bench["target"]["sha"],
        "reference": "human",
        "commits": metas,
        "files": sorted(
            {
                line.split(" b/", 1)[1].strip()
                for line in patch_text.splitlines()
                if line.startswith("diff --git ")
            }
        ),
        "patch_sha256": hashlib.sha256(patch_text.encode()).hexdigest(),
        "added_lines_sha256": hashlib.sha256(added.encode()).hexdigest(),
    }
    if check:
        record["applies_to_base"] = applies_to_cut(repo, bench["target"]["sha"], patch_path)
    (out_dir / "human.json").write_text(json.dumps(record, indent=2) + "\n")
    status = "" if not check else f" applies={record['applies_to_base']}"
    print(f"{case}: {len(metas)} commit(s), {len(record['files'])} file(s){status}")


def main(argv: list[str]) -> None:
    if not argv:
        raise SystemExit(__doc__)
    force = "--force" in argv
    check = "--check" in argv
    args = [a for a in argv if not a.startswith("--")]
    cases = cc.cases() if args[:1] == ["all"] else args
    for case in cases:
        record(case, force=force, check=check)


if __name__ == "__main__":
    main(sys.argv[1:])
