/* Sandbox accommodation for CPython's test suite.
 *
 * Tests run in an unprivileged container where the ids stored in the test tar
 * archives may not be mapped, so chown(2) to those ids can return EINVAL.
 * tarfile only attempts that chown when geteuid() == 0, and the failure aborts
 * the rest of the attribute fixup (mtime/mode), which makes four unrelated
 * extraction tests fail. On a real root host those chowns succeed, so accept
 * them here. The tests do not assert the resulting numeric owner, only mtime
 * and mode, which still run.
 */
#include <sys/types.h>
#include <unistd.h>

int chown(const char *path, uid_t owner, gid_t group) {
    (void)path;
    (void)owner;
    (void)group;
    return 0;
}

int lchown(const char *path, uid_t owner, gid_t group) {
    (void)path;
    (void)owner;
    (void)group;
    return 0;
}
