#!/usr/bin/env python3
"""Small helpers for the shell scripts: read case refs and registries."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def refs(case, dotted):
    data = json.loads((ROOT / "refs/cases.json").read_text())["cases"][case]
    value = data
    for part in dotted.split("."):
        value = value[part]
    return value


def registry_host(path):
    import yaml

    data = yaml.safe_load(Path(path).read_text())
    profile = data["models"][data.get("default") or next(iter(data["models"]))]
    base = profile.get("api_base") or ""
    host = base.split("//", 1)[-1].split("/", 1)[0]
    return host


def make_registry(src, dst):
    """Copy a registry, inlining api_key_file so the sandbox needs no key mount."""
    import os

    import yaml

    data = yaml.safe_load(Path(src).read_text())
    for profile in (data.get("models") or {}).values():
        key_file = profile.pop("api_key_file", None)
        if key_file and not profile.get("api_key"):
            path = Path(os.path.expanduser(str(key_file)))
            if not path.is_file():
                raise SystemExit(f"api_key_file not found: {path}")
            profile["api_key"] = path.read_text().strip()
    Path(dst).write_text(yaml.safe_dump(data, sort_keys=False))
    os.chmod(dst, 0o600)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "get":
        print(refs(sys.argv[2], sys.argv[3]))
    elif cmd == "host":
        print(registry_host(sys.argv[2]))
    elif cmd == "registry":
        make_registry(sys.argv[2], sys.argv[3])
    else:
        raise SystemExit(f"unknown command {cmd}")
