# Provenance and licenses

All inputs come from public repositories. Packs are built by
`scripts/build-case.sh` by fetching the pinned commits listed in
`refs/cases.json`; nothing is vendored here.

| case | upstream | license | fix commit | human backport (excluded) |
|---|---|---|---|---|
| runc | https://github.com/opencontainers/runc | Apache-2.0 | 2f74f4ae… | discovered per build |
| containerd | https://github.com/containerd/containerd | Apache-2.0 | 0ec1af4c… | discovered per build |
| postgres-15742 | https://github.com/postgres/postgres | PostgreSQL | 918683d1… | discovered per build |
| k8s-2270 | https://github.com/kubernetes/kubernetes | Apache-2.0 | a1d21b1a… | discovered per build |
| k8s-143087 | https://github.com/kubernetes/kubernetes | Apache-2.0 | patch (PR #143087) | 53f77f1 (release-1.35) |
| glibc | https://github.com/bminor/glibc | LGPL-2.1+ | c9188d33… | f18446d7 (release/2.31/master) |
| php81/82/83 | https://github.com/php/php-src | PHP-3.01 | 3584a98b… | merge chain into each branch |
| pgrls | https://github.com/postgres/postgres | PostgreSQL | 315c4e4e… | 4167810 (REL_14_STABLE) |
| pcre2 | https://github.com/PCRE2Project/pcre2 | BSD-3-Clause | a141712e… | none (release/pcre2-10.45 predates fix) |
| golang-crypto | https://github.com/golang/crypto | BSD-3-Clause | 7292932d… | v0.35.0 release tag only |
| valkey | https://github.com/valkey-io/valkey | BSD-3-Clause | fea0b406… | fdc142c6 (8.0) |
| rsync | https://github.com/RsyncProject/rsync | GPL-3.0-or-later | 859d44fa… | ac47b013, 04338c6b (lts/3.2) |
| cpython-tarfile | https://github.com/python/cpython | PSF-2.0 | 3612d8f5… | 19de092d (3.12), aa9eb5f7 (3.13), 4633f3f4 (3.11) |

`cases/k8s-143087/tests.patch` is a case-provided regression test (not the
fix). `cases/k8s-143087/fix.patch` is the public fix diff (PR #143087).

`cases/rsync/sandbox_setgroups.c` and
`cases/cpython-tarfile/sandbox_fakechown.c` are test-only LD_PRELOAD shims.
They emulate the root-host outcome of the daemon's `setgroups` call and of the
`chown` calls tarfile makes only as root, so the suites can run under
unprivileged container uid/gid mappings without altering project code or the
files the tests compare.

For target branch commits that are non-upstream names (`eval/...` in the
original benchmark), `refs/cases.json` records the real upstream branch under
`target.upstream_branch`; the pack creates the case-local branch name at the
pinned public SHA.

The fixture builder previously re-created several commits (author
`Backport Bench`/`Kubernetes Backport Test`) to compact history. This suite
uses the public commits directly, so those synthetic SHAs do not appear
anywhere.
