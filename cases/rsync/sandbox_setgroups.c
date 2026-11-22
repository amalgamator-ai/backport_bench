/* Sandbox accommodations for rsync's test suite.
 *
 * Tests run in an unprivileged container whose uid/gid mapping may deny
 * setgroups(2) or expose unmapped groups as the overflow gid:
 *   - rsync's daemon treats a setgroups EPERM as fatal (on a root host it
 *     succeeds), so the call is accepted here;
 *   - chgrp(1) on the overflow gid fails, which breaks the chgrp test's setup,
 *     so the overflow gid is hidden from getgroups().
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
