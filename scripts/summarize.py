#!/usr/bin/env python3
"""Summarize every completed run under results/<case>/<timestamp>/."""
import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    results = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "results"
    rows = []
    for path in sorted(results.glob("*/*/result.json")):
        try:
            data = json.loads(path.read_text())
        except ValueError:
            continue
        summary = data.get("summary") or {}
        tokens = data.get("tokens") or {}
        audit_path = path.parent / "audit.json"
        audit = "?"
        if audit_path.exists():
            audit = json.loads(audit_path.read_text()).get("status", "?")
        rows.append(
            {
                "case": data.get("case"),
                "outcome": summary.get("outcome") or "error",
                "wall_s": data.get("wall_s"),
                "input_tokens": tokens.get("input_tokens"),
                "output_tokens": tokens.get("output_tokens"),
                "audit": audit,
                "run": str(path.parent),
            }
        )
    if not rows:
        print("no results yet")
        return
    rows.sort(key=lambda r: (r["case"] or "", r["run"]))
    latest: dict[str, dict] = {}
    for r in rows:
        latest[r["case"]] = r
    header = f"{'case':16s} {'outcome':10s} {'wall':>8s} {'input':>10s} {'output':>9s} {'audit':6s} run"
    print(header)
    print("-" * len(header))
    ok = 0
    for case, r in latest.items():
        if r["outcome"] == "success":
            ok += 1
        wall = f"{r['wall_s']}s" if r["wall_s"] is not None else "-"
        inp = r["input_tokens"] if r["input_tokens"] is not None else "-"
        out = r["output_tokens"] if r["output_tokens"] is not None else "-"
        print(
            f"{case:16s} {r['outcome']:10s} {wall:>8s} {inp:>10} {out:>9} "
            f"{r['audit']:6s} {r['run']}"
        )
    print(f"\n{ok}/{len(latest)} cases succeeded")
    csv_path = results / "summary.csv"
    with csv_path.open("w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(latest[next(iter(latest))]))
        writer.writeheader()
        writer.writerows(latest.values())
    print(f"csv: {csv_path}")


if __name__ == "__main__":
    main()
