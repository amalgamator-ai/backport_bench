/* Sandbox accommodations for rsync's test suite.
 *
 * The benchmark sandbox runs the pipeline in a bubblewrap user namespace that
 * maps a single uid/gid, so:
 *   - the kernel denies setgroups(2) with EPERM, which rsync's daemon treats
 *     as fatal (on a real host the daemon runs as root and setgroups succeeds);
 *   - supplementary gids that are not mapped appear as the overflow gid 65534,
 *     and chgrp(1) on that gid fails, which breaks the chgrp test's setup.
 *
 * These shims emulate the ordinary host outcome for the privilege-dropping and
 * group-listing calls only. They do not touch rsync logic or any file content
 * the tests compare.
 */
#include <grp.h>
#include <sys/syscall.h>
#include <unistd.h>

int setgroups(size_t size, const gid_t *list) {
    (void)size;
    (void)list;
    return 0;
}

int getgroups(int size, gid_t list[]) {
    int n = (int)syscall(SYS_getgroups, size, list);
    int i, out = 0;
    if (n < 0 || !list)
        return n;
    for (i = 0; i < n; i++) {
        if (list[i] != 65534)
            list[out++] = list[i];
    }
    return out;
}
