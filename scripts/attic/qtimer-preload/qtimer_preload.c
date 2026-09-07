/* qtimer_preload.c — x86_64 LD_PRELOAD interposer to find long blocking polls
 * in Cadence Qt tools running under FEX.
 *
 * Intercepts ppoll() (plus the Qt QTimer/QObject timer entry points) and, when
 * a poll timeout is >= 20s, appends a raw backtrace to $QTIMER_LOG (default
 * /tmp/qtimer.log). Run the tool with LD_PRELOAD pointed at the built .so,
 * reproduce the stall, then resolve the logged addresses against the tool's
 * binary/libs with the x86_64 addr2line:
 *
 *   x86_64-unknown-linux-gnu-addr2line -f -C -e <binary> 0x<addr>
 *
 * This is how the ~135s virtuoso launch stall was pinned down to
 * QCadenceStyle::cdsRoot() -> QProcess::waitForStarted/Finished(30000).
 *
 * Build (cross-compiles the x86_64 .so from the aarch64 host):
 *   nix build --impure --expr \
 *     "(import /home/tianyixia/nixos-config/scripts/qtimer-preload/build.nix)" \
 *     -o result
 *   cp result/qtimer_preload.so ~/.cadence/qtimer_preload.so
 * Run:
 *   LD_PRELOAD=$HOME/.cadence/qtimer_preload.so \
 *     QTIMER_LOG=$HOME/.cadence/qtimer.log virtuoso ...
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <time.h>
#include <poll.h>
#include <signal.h>

static const char *log_path(void) {
    const char *p = getenv("QTIMER_LOG");
    return p && p[0] ? p : "/tmp/qtimer.log";
}

static void log_bt(const char *what) {
    FILE *f = fopen(log_path(), "a");
    if (!f) return;
    fprintf(f, "=== %s t=%ld\n", what, (long)time(NULL));
    void *bt[40];
    int n = backtrace(bt, 40);
    for (int i = 0; i < n; i++)
        fprintf(f, "  #%02d %p\n", i, bt[i]);
    fprintf(f, "\n");
    fflush(f);
    fclose(f);
}

typedef void (*fn_void_int)(void *, int);

void _ZN6QTimer5startEi(void *self, int msec) {
    static fn_void_int real = NULL;
    if (!real) real = (fn_void_int)dlvsym(RTLD_NEXT, "_ZN6QTimer5startEi", "Qt_5");
    log_bt("QTimer::start(int)");
    if (real) real(self, msec);
}
void _ZN6QTimer11setIntervalEi(void *self, int msec) {
    static fn_void_int real = NULL;
    if (!real) real = (fn_void_int)dlvsym(RTLD_NEXT, "_ZN6QTimer11setIntervalEi", "Qt_5");
    log_bt("QTimer::setInterval(int)");
    if (real) real(self, msec);
}
void _ZN6QTimer5startEv(void *self) {
    static void (*real)(void *) = NULL;
    if (!real) real = (void (*)(void *))dlvsym(RTLD_NEXT, "_ZN6QTimer5startEv", "Qt_5");
    log_bt("QTimer::start()");
    if (real) real(self);
}
int _ZN7QObject10startTimerEi(void *self, int interval) {
    static int (*real)(void *, int) = NULL;
    if (!real) real = (int (*)(void *, int))dlvsym(RTLD_NEXT, "_ZN7QObject10startTimerEi", "Qt_5");
    log_bt("QObject::startTimer(int)");
    return real ? real(self, interval) : 0;
}

/* catch the 30s poll (the stall signature) */
int ppoll(struct pollfd *fds, nfds_t nfds, const struct timespec *tmo,
          const sigset_t *sigmask) {
    static int (*real)(struct pollfd *, nfds_t, const struct timespec *, const sigset_t *) = NULL;
    if (!real) real = (int (*)(struct pollfd *, nfds_t, const struct timespec *, const sigset_t *))dlvsym(RTLD_NEXT, "ppoll", "GLIBC_2.4");
    if (tmo && tmo->tv_sec >= 20) log_bt("ppoll(>=20s)");
    return real(fds, nfds, tmo, sigmask);
}
