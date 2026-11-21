# Backport bench

A self-contained benchmark suite for Amalgamator's `auto_bug_fix` pipeline.
Each case takes a public upstream security fix, points the pipeline at an
older release branch at a commit *before* the fix landed there, and asks the
agent to port it. The human backport is excluded from the case: the run cannot
see it locally and cannot fetch it from the network.

## Layout

```
refs/cases.json          public upstream URL + pinned SHAs per case
cases/<name>/case.yaml   pipeline config (portable paths)
cases/<name>/repo.git    sanitized pack, built from public refs (gitignored)
cases/<name>/fix.patch   fix as a patch (patch-mode cases only)
scripts/                 build, verify, run, audit, summarize
models/                  registry template; models.local.yaml is yours (gitignored)
grading/<name>/          human fix + reference numbers (never mounted)
results/                 run artifacts (gitignored)
cache/                   full upstream mirrors, one per repo (gitignored)
```

## Install and setup

### 1. Clone amalgamator and the bench side by side

Install `uv` and the base build tools first if they are missing (commands in
step 3). `AMALGAMATOR` defaults to `../amalgamator`, so this layout works out
of the box:

```bash
mkdir -p ~/work && cd ~/work
git clone <amalgamator-repo-url> amalgamator
git clone https://github.com/amalgamator-ai/backport_bench.git
cd amalgamator && uv sync --extra test --extra dev && cd ..
```

The runner expects a built virtualenv at `$AMALGAMATOR/.venv`. If your
checkout lives elsewhere, export `AMALGAMATOR=/path/to/amalgamator`.

### 2. Point the bench at a model

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

### 3. Check the environment

```bash
./scripts/check-prereqs.sh
```

It verifies `git`, Python, `bubblewrap`, `flock`, the amalgamator venv, the
model registry, Go + the x/crypto module cache, Tcl, autotools, free disk and
the capability to build a user/network namespace. Install the base tools with
your package manager, for example:

```bash
sudo dnf install bubblewrap git python3 gcc make     # Fedora
sudo apt install bubblewrap git python3 build-essential  # Debian/Ubuntu
curl -LsSf https://astral.sh/uv/install.sh | sh      # uv
```

Toolchain locations default to `$HOME/toolchains` (`TOOLCHAINS`) and
`$HOME/w8hw-tools` (`W8HW_ENV`); export overrides if you keep them elsewhere.

### 4. Build the case packs

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

### 5. Run

```bash
./scripts/run-case.sh pcre2          # quick single case (under a minute)
./scripts/run-case.sh runc           # a long case
./scripts/run-suite.sh --parallel 3  # all cases, bounded concurrency
./scripts/summarize.py               # per-case table + results/summary.csv
```

Each run happens inside a bubblewrap sandbox:

- filesystem: only the case pack copy, a fresh workspace, the amalgamator
  checkout, the model registry, and the build toolchains are mounted;
- network: a new network namespace whose only reachable peer is a host-side
  TLS pass-through proxy for the model endpoint. GitHub, sourceware and every
  other host are unreachable;
- after the run, `audit-run.sh` scans the transcript for `git fetch`, `curl`,
  `git log --all`, the upstream host and the forbidden SHAs. A run that trips
  the audit is reported as invalid.

The model comes from `models/models.local.yaml`; keep
`params.reasoning_effort: medium` for comparable results.

### Sandbox test shims

The sandbox is a bubblewrap user namespace with only uid/gid 0 mapped, so a
few test suites see host-like privileges but cannot use every uid/gid:

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

### Toolchains and paths

Nothing is tied to one machine; scripts read these variables and case build
commands expand them inside the sandbox:

| variable | default | used for |
|---|---|---|
| `AMALGAMATOR` | `../amalgamator` beside this repo | amalgamator checkout |
| `TOOLCHAINS` | `$HOME/toolchains` | Go toolchain and module cache, Tcl, RPM/perl build roots |
| `W8HW_ENV` | `$HOME/w8hw-tools` | autotools and PHP build environment |
| `UV_PYTHON_HOME` | `$HOME/.local` | uv/pip install root |

Export an override before `build-all.sh`/`run-suite.sh` if your layout
differs. `scripts/check-prereqs.sh` verifies:

- `${TOOLCHAINS}/go` plus `GOMODCACHE` at `${TOOLCHAINS}/gomodcache`
  populated for x/crypto v0.33.0 (`go mod download` once, with network);
- `${TOOLCHAINS}/tcl` for Valkey's Tcl test harness;
- `${W8HW_ENV}/env/bin` autotools for rsync's bootstrap;
- CPython needs only system `python3`, gcc and make.

## Adding a case

1. Find the public fix commit and the target branch commit before the human
   backport (or before the fix).
2. Add an entry to `refs/cases.json` (URL, source/target SHA, fix kind,
   optional `target.upstream_branch` for discovery).
3. Create `cases/<name>/case.yaml` with portable paths
   (`${BACKPORT_REPOS}/repo.git`, `${BACKPORT_WORK}`).
4. `./scripts/build-case.sh <name>` and fix anything the leak check reports.
5. `./scripts/run-case.sh <name>`; record reference numbers in `grading/`.

No runner code changes are needed for a normal case.
