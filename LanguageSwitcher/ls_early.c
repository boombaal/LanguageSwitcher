// Runs before main() and before Swift @main. If this never appears in
// /tmp/LanguageSwitcher-boot.log, the C object was not linked (wrong .app) or
// the process did not start loading the binary.
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((constructor(0)))
static void ls_very_early_ctor(void) {
    char buf[256];
    int n;
    pid_t mypid = getpid();
    n = snprintf(buf, sizeof buf, "LS-ctor (pre-Swift) pid=%d euid=%d\n", (int)mypid, (int)geteuid());
    if (n > 0) (void)write(2, buf, (size_t)n);
    int fd = open("/tmp/LanguageSwitcher-boot.log", O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) {
        n = snprintf(buf, sizeof buf, "LS-ctor: open boot log err=%d\n", errno);
        (void)write(2, buf, (size_t)(n < 0 ? 0 : n));
        return;
    }
    n = snprintf(buf, sizeof buf, "LS-ctor (pre-Swift) pid=%d euid=%d\n", (int)mypid, (int)geteuid());
    if (n > 0) (void)write(fd, buf, (size_t)n);
    (void)close(fd);
    /* $HOME: отдельный путь-«маячок» и тот же файл, куда потом пишет Swift: LanguageSwitcher-launch.log */
    {
        const char *home = getenv("HOME");
        if (home) {
            char hpath[1024];
            int ni = snprintf(hpath, sizeof hpath, "%s/LanguageSwitcher-ctor-home.log", home);
            if (ni > 0 && ni < (int)sizeof hpath) {
                int hfd = open(hpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
                if (hfd >= 0) {
                    if (n > 0) (void)write(hfd, buf, (size_t)n);
                    (void)close(hfd);
                } else {
                    dprintf(2, "ls_early: open ctor-home err=%d\n", errno);
                }
            }
            ni = snprintf(hpath, sizeof hpath, "%s/LanguageSwitcher-launch.log", home);
            if (ni > 0 && ni < (int)sizeof hpath) {
                int lfd = open(hpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
                if (lfd >= 0) {
                    (void)dprintf(
                        lfd, "C pre-Swift: LanguageSwitcher-launch.log ok pid=%d (Swift appends after)\n",
                        (int)mypid
                    );
                    (void)close(lfd);
                } else {
                    dprintf(2, "ls_early: open launch.log err=%d path=%s\n", errno, hpath);
                }
            }
            /* Каталог как у Swift: ~/Library/Application Support/LanguageSwitcher/ + маркер */
            ni = snprintf(
                hpath, sizeof hpath, "%s/Library/Application Support/LanguageSwitcher", home
            );
            if (ni > 0 && ni < (int)sizeof hpath) {
                if (mkdir(hpath, 0700) == -1 && errno != EEXIST) {
                    dprintf(2, "ls_early: mkdir Application Support/LanguageSwitcher err=%d\n", errno);
                } else {
                    (void)snprintf(
                        hpath, sizeof hpath,
                        "%s/Library/Application Support/LanguageSwitcher/launch.c-marker", home
                    );
                    int mfd = open(hpath, O_WRONLY | O_CREAT | O_APPEND, 0600);
                    if (mfd >= 0) {
                        dprintf(
                            mfd, "C App Support ok pid=%d (Swift also writes launch.log here)\n",
                            (int)mypid
                        );
                        (void)close(mfd);
                    }
                }
            }
        } else {
            dprintf(2, "ls_early: getenv(HOME) is null\n");
        }
    }
}
