# Backport bench

A self-contained benchmark suite for Amalgamator's `auto_bug_fix` pipeline.
Each case takes a public upstream security fix, points the pipeline at an
older release branch at a commit *before* the fix landed there, and asks the
agent to port it. The human backport is excluded from the case: the run cannot
see it locally and cannot fetch it from the network.

## Layout

```
cases/<name>/case.yaml   single config: bench: (refs, fix, forbidden backports)
                         and pipeline: (issue, build/test, advanced, model)
cases/<name>/human/      recorded human backport + provenance (never mounted)
cases/<name>/run/        generated from case.yaml; the only directory mounted (gitignored)
cases/<name>/check-prereqs.sh  checks run inside the case image
cases/<name>/Containerfile     per-case image build (FROM a shared base)
cases/<name>/repo.git    sanitized pack, built from public refs (gitignored)
cases/<name>/fix.patch   fix as a patch (patch-mode cases only)
scripts/                 images, build, verify, render, run, audit, summarize
models/                  registry template; models.local.yaml is yours (gitignored)
results/                 run artifacts (gitignored)
cache/                   full upstream mirrors, one per repo (gitignored)
```

`scripts/render-case.sh <name>` regenerates `cases/<name>/run/`: the pipeline
section with `repository`, `branches` and `fix` derived from `bench`, plus
`fix.patch` for patch-mode cases. It refuses to emit if a forbidden SHA, the
upstream URL or the target cut SHA would appear in the output.

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

Two shared toolchain bases are built once (network needed): `bench-tools`
(Fedora with gcc/make/autotools/bison/flex/cmake/Tcl plus the PHP and glibc
build deps) and `bench-go` (golang:1.25 with the x/crypto module cache). Every
case is then built from its own `cases/<case>/Containerfile`, which starts
`FROM` one of those bases, copies the case's `check-prereqs.sh` and runs it, so
prerequisites are validated at build time and each case gets its own image ID.
Rebuild with `--force` after changing a base or a `check-prereqs.sh`.

### 5. Build the case packs

```bash
./scripts/build-all.sh
```

`build-all.sh` clones each upstream once into `cache/`, then creates each
sanitized pack: only the source ref (at the fix commit) and the target ref (at
the pre-fix cut), full history so the pipeline has a real merge-base, no
remotes, tags, reflogs or unreachable objects. It then runs the leak check:

- every ref sits exactly at its pinned public commit;
- the human backport commits listed in `bench.forbidden` must not exist in the
  pack at all, and build-time discovery fails the case if it finds a
  same-subject backport that is not listed there;
- no ref other than the case refs;
- the fix must not be an ancestor of the target;
- no unreachable objects (so `git fsck --lost-found` finds nothing).

A failing check aborts the case. The target tree hash is printed in the log.

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
  the project, pack, results and cache are never part of the image;
- filesystem: read-only root, with only the sanitized pack copy, a fresh
  workspace, the amalgamator checkout, the rendered case input at
  `cases/<case>/run`, the model registry and the model socket mounted;
  `cache/`, `results/` and `$HOME` are not visible;
- network: `--network=none`; the model is reached through a Unix socket to a
  host-side TLS pass-through proxy, so no upstream host or DNS is reachable;
- after the run, `audit-run.sh` scans the transcript for `git fetch`, `curl`,
  `git log --all`, the upstream host and forbidden SHAs, and asserts from
  `container.json` that the network mode is `none` and the mount set matches
  the whitelist. A run that trips the audit is reported as invalid.

The model comes from `models/models.local.yaml`; keep
`params.reasoning_effort: medium` for comparable results.

### Human backport and comparison

Each case records the human backport that later landed on the target branch,
so the AI result can be compared against it:

```bash
./scripts/record-human.sh all --check
./scripts/compare-all.sh                 # every case with a run
./scripts/compare-case.sh valkey results/valkey/<timestamp>
```

`record-human.sh` derives `cases/<name>/human/human.patch` and `human.json`
from the local `cache/` mirror, using `bench.human`:

- `mode: commits` — the backport commits (from `human.commits`, else
  `bench.forbidden`) that were merged into the target branch;
- `mode: none` — no human backport exists (pcre2, golang-crypto, php81); the
  comparison then uses the upstream fix commit as the reference.

The patch carries a header per commit, the commit list, file list, hashes and
whether it applies cleanly to the target cut. `cases/<name>/human/` is never
mounted into a run container (only `cases/<name>/run/` is), and the render and
pre-mount checks fail if any human-backport line would appear in the rendered
input.

`compare-case.sh` / `compare-all.sh` run on the host after the container exits
and ask the model to compare the AI `candidate.patch` with the reference: same
bug fixed, mechanism, completeness, extra changes, test coverage, risks and a
verdict with confidence. Inputs include both diffs, the reference's file stat
and the target-cut code for the files the AI touched. Output:

```
results/<case>/<timestamp>/comparison.json   structured verdict
results/<case>/<timestamp>/comparison.md     human-readable report
results/comparison.csv                       one row per judged case
```

The judge uses the registry's default profile; set `JUDGE_PROFILE` (or pass
`--profile`) to use a dedicated profile, e.g. a stronger model with
`temperature: 0`.

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
| `localhost/bench-tools:1` | `fedora:44` + dnf build tools + Tcl 8.6 | base for the C, autotools, PHP, glibc, PostgreSQL, CPython, Valkey and PCRE2 cases |
| `localhost/bench-go:1` | `golang:1.25` + `golang.org/x` module cache | base for runc, containerd, Kubernetes and golang.org/x/crypto |
| `localhost/bench/<case>:1` | `cases/<case>/Containerfile`, which starts `FROM` its base and runs `check-prereqs.sh` | that case only |

Layers are shared with the base, so all case images together still take about
2 GB. `scripts/build-images.sh` builds offline (`--pull=never --network=none`)
and records the resulting image IDs in `images.lock.json`. The only host paths
a run mounts are the amalgamator checkout, the case directory, the run
directory and the uv Python installation that backs the venv; there are no host
toolchains to configure. `TOOLCHAINS` (default `$HOME/toolchains`) is used only
when building the two bases.

## Adding a case

1. Find the public fix commit and the target branch commit before the human
   backport (or before the fix).
2. Create `cases/<name>/case.yaml` with a `bench:` section (upstream URL,
   source/target SHA, fix kind, optional `target.upstream_branch`, `forbidden`
   human-backport SHAs and `human: {mode: commits|none}`) and a `pipeline:`
   section (issue id, description, build/test commands using image paths only,
   advanced flags). Do not repeat repository, branch or fix fields there —
   they are derived.
3. Add `cases/<name>/check-prereqs.sh` (runs inside the image; exit non-zero
   and print `missing: ...` when a tool is absent).
4. Add `cases/<name>/Containerfile` (`FROM localhost/bench-tools:1` or
   `bench-go:1`, copy and run `check-prereqs.sh`) and a `.containerignore`
   that keeps the pack and case data out of the build context.
5. `./scripts/build-case.sh <name>` — builds the pack, runs the leak check and
   discovery guard, then renders `cases/<name>/run/`.
6. `./scripts/record-human.sh <name> --check` — records `cases/<name>/human/`.
7. `./scripts/build-images.sh <name>` and `./scripts/check-prereqs.sh <name>`.
8. `./scripts/run-case.sh <name>`, then `./scripts/summarize.py` for the run
   table and `./scripts/compare-case.sh <name> <run>` for the AI-vs-human
   comparison.

Cases share the `bench-tools` or `bench-go` base; add steps to the case's
Containerfile only when it requires extra packages (that build step then needs
network access).
