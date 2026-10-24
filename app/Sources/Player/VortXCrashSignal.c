#include "VortXCrashSignal.h"

#include <execinfo.h>
#include <signal.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

/* atomic_flag is guaranteed lock-free by C11. The readiness/count atomics also
 * participate in this terminal boundary: reject a target rather than silently
 * permitting a locking implementation. Inspect the real compiler output before
 * claiming platform code-generation proof; this source has not been compiled. */
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "crash signal state requires lock-free int atomics");

enum { kFramesCapacity = 128, kScratchCapacity = 32, kMaxSignal = 32 };
static const int gFatalSignals[] = { SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP };

/* Ordinary install initializes these once before publishing readiness and before
 * installing any callback. After that, only the terminal claim winner mutates
 * frames/scratch. All storage has process lifetime; there is no heap or ARC. */
static int gMarkerFD = -1;
static void *gFrames[kFramesCapacity];
static unsigned char gScratch[kScratchCapacity];
static struct sigaction gPrevActions[kMaxSignal];
static unsigned char gPreviousActionValid[kMaxSignal];
static atomic_flag gInstallClaimed = ATOMIC_FLAG_INIT;
static atomic_flag gAlreadyWrote = ATOMIC_FLAG_INIT;
static _Atomic int gReady = 0;
static _Atomic int gInstalledSignalCount = 0;

static void asyncSafeWrite(int fd, const unsigned char *cursor, size_t remaining) {
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) { break; }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
}

static void asyncSafeWriteByte(int fd, unsigned char byte) {
    (void)write(fd, &byte, 1);
}

static void asyncSafeWriteEpoch(int fd, time_t value) {
    uint64_t remaining = value > 0 ? (uint64_t)value : 0;
    size_t index = kScratchCapacity;
    do {
        gScratch[--index] = (unsigned char)('0' + remaining % 10);
        remaining /= 10;
    } while (remaining > 0 && index > 0);
    asyncSafeWrite(fd, gScratch + index, kScratchCapacity - index);
}

static void asyncSafeWriteSignalName(int fd, int sig) {
    const unsigned char *name;
    size_t length;
    switch (sig) {
        case SIGABRT: name = (const unsigned char *)"SIGABRT"; length = 7; break;
        case SIGSEGV: name = (const unsigned char *)"SIGSEGV"; length = 7; break;
        case SIGILL:  name = (const unsigned char *)"SIGILL";  length = 6; break;
        case SIGBUS:  name = (const unsigned char *)"SIGBUS";  length = 6; break;
        case SIGFPE:  name = (const unsigned char *)"SIGFPE";  length = 6; break;
        case SIGTRAP: name = (const unsigned char *)"SIGTRAP"; length = 7; break;
        default:      name = (const unsigned char *)"SIGNAL";  length = 6; break;
    }
    asyncSafeWrite(fd, name, length);
}

int vortx_crash_signal_claim_marker(void) {
    if (!atomic_load_explicit(&gReady, memory_order_acquire) || gMarkerFD < 0) { return -1; }
    if (atomic_flag_test_and_set_explicit(&gAlreadyWrote, memory_order_relaxed)) { return -1; }
    return gMarkerFD;
}

static void vortxSignalHandler(int sig) {
    int fd = vortx_crash_signal_claim_marker();
    if (fd >= 0) {
        /* Preserve the existing marker wire shape exactly: name, epoch, newline,
         * symbolized stack, final newline. The pre-warmed backtrace/symbolizer
         * remain BEST-EFFORT: Darwin does not promise these two calls are POSIX
         * async-signal-safe. Moving them to C does not strengthen that contract. */
        asyncSafeWriteSignalName(fd, sig);
        asyncSafeWriteByte(fd, ' ');
        asyncSafeWriteEpoch(fd, time(NULL));
        asyncSafeWriteByte(fd, '\n');
        int count = backtrace(gFrames, kFramesCapacity);
        backtrace_symbols_fd(gFrames, count, fd);
        asyncSafeWriteByte(fd, '\n');
        (void)fsync(fd);
    }

    /* Even a losing writer still chains. Restore the entire original action,
     * including its mask/flags, then redeliver exactly as the previous reporter
     * did. The current signal remains masked until this handler returns. */
    if (sig >= 0 && sig < kMaxSignal && gPreviousActionValid[sig]) {
        (void)sigaction(sig, &gPrevActions[sig], NULL);
    } else {
        (void)signal(sig, SIG_DFL);
    }
    (void)raise(sig);
}

int vortx_crash_signal_install(int marker_fd) {
    if (atomic_flag_test_and_set_explicit(&gInstallClaimed, memory_order_relaxed)) {
        return atomic_load_explicit(&gInstalledSignalCount, memory_order_relaxed);
    }
    gMarkerFD = marker_fd;

    /* Warm the same backtrace path in ordinary launch. This mitigates first-use
     * loading only; it is not an allocation/signal-safety guarantee. */
    (void)backtrace(gFrames, kFramesCapacity);
    (void)signal(SIGPIPE, SIG_IGN);

    /* First snapshot every action before any callback can observe the table.
     * App launch owns this process-wide registration window; a concurrently
     * installing third-party reporter requires external coordination. */
    size_t signalCount = sizeof(gFatalSignals) / sizeof(gFatalSignals[0]);
    for (size_t i = 0; i < signalCount; ++i) {
        int sig = gFatalSignals[i];
        if (sig >= 0 && sig < kMaxSignal && sigaction(sig, NULL, &gPrevActions[sig]) == 0) {
            gPreviousActionValid[sig] = 1;
        }
    }

    struct sigaction action = {0};
    action.sa_flags = 0;
    (void)sigemptyset(&action.sa_mask);
    action.sa_handler = vortxSignalHandler;

    /* Release/acquire publishes fd, saved actions and storage initialization.
     * No mutable Swift global or non-Sendable pointer crosses this boundary. */
    atomic_store_explicit(&gReady, 1, memory_order_release);
    int installed = 0;
    for (size_t i = 0; i < signalCount; ++i) {
        int sig = gFatalSignals[i];
        if (sig >= 0 && sig < kMaxSignal && gPreviousActionValid[sig] &&
            sigaction(sig, &action, NULL) == 0) {
            ++installed;
        }
    }
    atomic_store_explicit(&gInstalledSignalCount, installed, memory_order_relaxed);
    return installed;
}
