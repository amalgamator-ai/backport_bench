# Backport bench

A self-contained benchmark suite for Amalgamator's `auto_bug_fix` pipeline.
Each case takes a public upstream security fix, points the pipeline at an
older release branch at a commit *before* the fix landed there, and asks the
agent to port it. The human backport is excluded from the case: the run cannot
see it locally and cannot fetch it from the network.

## Layout

```
refs/cases.json          public upstream URL + pinned SHAs per case
cases/<name>/case.yaml   pipeline config (image paths)
cases/<name>/check-prereqs.sh  checks run inside the case image
cases/<name>/repo.git    sanitized pack, built from public refs (gitignored)
cases/<name>/fix.patch   fix as a patch (patch-mode cases only)
scripts/                 images, build, verify, run, audit, summarize
models/                  registry template; models.local.yaml is yours (gitignored)
grading/<name>/          human fix + reference numbers (never mounted)
results/                 run artifacts (gitignored)
cache/                   full upstream mirrors, one per repo (gitignored)
```

## Install and setup

### 1. Install the base tools

```bash
sudo dnf install podman git python3 curl                  # Fedora
sudo apt install podman git python3 curl                  # Debian/Ubuntu
curl -LsSf https://astral.sh/uv/install.sh | sh           # uv, if missing
```

All case toolchains live inside the container images; the host needs only
podman, git, python3 and uv. Use rootless podman with `/etc/subuid` and
`/etc/subgid` configured for your user (the default on Fedora). If podman is
not installed, set `PODMAN_ROOT` to a rootless podman tree; `scripts/podman-env.sh`
falls back to `$HOME/toolchains/podman-root`.

### 2. Clone amalgamator and the bench side by side

`AMALGAMATOR` defaults to `../amalgamator`, so this layout works out of the
box:

```bash
mkdir -p ~/work && cd ~/work
git clone https://github.com/amalgamator-ai/amalgamator.git amalgamator
git clone https://github.com/amalgamator-ai/backport_bench.git
cd amalgamator && uv sync --extra test --extra dev && cd ..
```

The runner expects a built virtualenv at `$AMALGAMATOR/.venv`. If your
checkout lives elsewhere, export `AMALGAMATOR=/path/to/amalgamator`.

### 3. Point the bench at a model

```bash
cd backport_bench
./scripts/setup.sh
```

The script asks, in order:

1. profile id (keep `deepseek-v41-flash`; the case configs reference it),
2. provider (`litellm`, `anthropic`, ...),
3. served model id (for example `openai/my-model`),
4. API base URL (for example `https://llm.example.com/v1`),
5. API key file (default `~/.config/amalgamator/keys/<provider>`).

If the key file does not exist, it offers to read the key silently and write it
with `0600`. The generated `models/models.local.yaml` (gitignored, mode 0600)
records only the key *path*, never the key. Non-interactive use:

```bash
./scripts/setup.sh --no-input \
  --model openai/my-model \
  --api-base https://llm.example.com/v1 \
  --api-key-file ~/.config/amalgamator/keys/litellm
```

### 4. Build the case images

```bash
cd ~/work/backport_bench
./scripts/build-images.sh
```

Two shared bases are built once (network needed): `bench-tools` (Fedora with
gcc/make/autotools/bison/flex/cmake/Tcl plus the PHP and glibc build deps) and
`bench-go` (golang:1.25 with the x/crypto module cache). Each case then gets
its own tag `localhost/bench/<case>:1`. Re-run with `--force` after changing a
base.

### 5. Build the case packs

```bash
./scripts/build-all.sh
```

`build-all.sh` clones each upstream once into `cache/`, then creates each
sanitized pack: only the source ref (at the fix commit) and the target ref (at
the pre-fix cut), full history so the pipeline has a real merge-base, no
remotes, tags, reflogs or unreachable objects. It then runs the leak check:

- the human backport commit must not exist in the pack at all;
- no ref other than the two case refs;
- the fix must not be an ancestor of the target;
- no unreachable objects (so `git fsck --lost-found` finds nothing).

A failing check aborts the case.

### 6. Check the environment

```bash
./scripts/check-prereqs.sh
```

It checks the host runner (podman, git, Python, `flock`, the amalgamator venv,
the model registry, disk) and then runs each case's own
`cases/<name>/check-prereqs.sh` inside that case's image. Every line must be
`ok` before running the suite.

### 7. Run

```bash
./scripts/run-case.sh pcre2          # quick single case (under a minute)
./scripts/run-case.sh runc           # a long case
./scripts/run-suite.sh --parallel 3  # all cases, bounded concurrency
./scripts/summarize.py               # per-case table + results/summary.csv
```

Each run happens in that case's own container:

- image: `localhost/bench/<case>:1`, whose only content is public toolchains;
  the project, pack, grading data and results are never part of the image;
- filesystem: read-only root, with only the sanitized pack copy, a fresh
  workspace, the amalgamator checkout, the case config, the model registry and
  the model socket mounted; `grading/`, `cache/`, `results/` and `$HOME` are
  not visible;
- network: `--network=none`; the model is reached through a Unix socket to a
  host-side TLS pass-through proxy, so no upstream host or DNS is reachable;
- after the run, `audit-run.sh` scans the transcript for `git fetch`, `curl`,
  `git log --all`, the upstream host and forbidden SHAs, and asserts from
  `container.json` that the network mode is `none` and the mount set matches
  the whitelist. A run that trips the audit is reported as invalid.

The model comes from `models/models.local.yaml`; keep
`params.reasoning_effort: medium` for comparable results.

### Container test shims

A few test suites need root-like uid/gid behaviour. These shims keep them
working under unprivileged container mappings:

- `cases/rsync/sandbox_setgroups.c` accepts the daemon's `setgroups` call and
  hides the unmapped overflow gid from `getgroups`, so `make check` runs as it
  would for root on a normal host;
- `cases/cpython-tarfile/sandbox_fakechown.c` accepts `chown` to the archive's
  uids, which tarfile only attempts as root; the four extraction tests then
  check mtime and mode as usual.

Both are compiled by the case's `test_command` and loaded with `LD_PRELOAD`;
they do not modify the project under test or the files the tests compare.

## Cases

| case | project | difficulty | exercises |
|---|---|---|---|
| runc | runc 1.2 | hard | three-CVE coordinated hardening, vendored deps |
| containerd | containerd 1.7 | medium | label propagation fix, vendored Go |
| postgres-15742 | PostgreSQL 14 | medium | CVE fix with SQL regression tests |
| k8s-2270 | Kubernetes 1.34 | hard | large vendored tree |
| k8s-143087 | Kubernetes 1.35 | simple | patch-file ingest, pre-ported regression test |
| glibc | glibc 2.31 | hard | EOL branch, memory-safety fix |
| php81 / php82 / php83 | PHP 8.1/8.2/8.3 | extreme | engine-wide bailout change across EOL branches |
| pgrls | PostgreSQL 14 | hard | view row visibility fix, `make check` |
| pcre2 | PCRE2 10.45 | easy | one matcher fix plus a RunTest regression, CMake/ctest |
| golang-crypto | golang.org/x/crypto v0.33.0 | medium | SSH KEX queue cap, Go modules from a pinned cache |
| valkey | Valkey 8.0 | medium | malformed-zipmap RESTORE fix, vendored C deps |
| rsync | rsync 3.2 LTS | hard | two-commit daemon TOCTOU backport, full test suite |
| cpython-tarfile | CPython 3.12 | extreme | four-CVE tarfile filter/repath backport, three test modules |

### Images

| image | built from | used by |
|---|---|---|
| `localhost/bench-tools:1` | `fedora:44` + dnf build tools + Tcl 8.6 | C, autotools, PHP, glibc, PostgreSQL, CPython, Valkey, PCRE2 cases |
| `localhost/bench-go:1` | `golang:1.25` + `golang.org/x` module cache | runc, containerd, Kubernetes, golang.org/x/crypto |
| `localhost/bench/<case>:1` | tag of one of the above | that case only |

`scripts/build-images.sh` records image IDs in `images.lock.json`. The only
host paths a run mounts are the amalgamator checkout, the case directory, the
run directory and the uv Python installation that backs the venv; there are no
host toolchains to configure. `TOOLCHAINS` (default `$HOME/toolchains`) is used
only when building `bench-go` and when copying Tcl 8.6 into `bench-tools`.

## Adding a case

1. Find the public fix commit and the target branch commit before the human
   backport (or before the fix).
2. Add an entry to `refs/cases.json` (URL, source/target SHA, fix kind,
   optional `target.upstream_branch` for discovery).
3. Create `cases/<name>/case.yaml` with the container paths
   (`${BACKPORT_REPOS}/repo.git`, `${BACKPORT_WORK}`) and build/test commands
   that use image paths only.
4. Add `cases/<name>/check-prereqs.sh` (runs inside the image; exit non-zero
   and print `missing: ...` when a tool is absent).
5. `./scripts/build-case.sh <name>` and fix anything the leak check reports.
6. `./scripts/build-images.sh <name>` and `./scripts/check-prereqs.sh <name>`.
7. `./scripts/run-case.sh <name>`; record reference numbers in `grading/`.

Cases share the `bench-tools` or `bench-go` base; no Dockerfile is needed
unless a case requires extra packages.
