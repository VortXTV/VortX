#ifndef VORTX_CRASH_SIGNAL_H
#define VORTX_CRASH_SIGNAL_H

#ifdef __cplusplus
extern "C" {
#endif

/* Ordinary launch only. Owns no fd lifetime: marker_fd must remain open until
 * process exit. The first call freezes it; later calls never replace it. Returns
 * the number of fatal-signal handlers installed (or the count currently known
 * if an unsupported concurrent caller races the ordinary installation).
 * This is not a general reporter-registration API: launch must serialize other
 * process-wide fatal-handler installation with this call. */
int vortx_crash_signal_install(int marker_fd);

/* Shared signal/exception terminal-write claim. Returns the original marker fd
 * to the first winner only, or -1 when unavailable/already claimed. No heap,
 * lock, Foundation, Swift callback, or reset is involved. The caller owns the
 * resulting write and fsync; the fd is never closed or recycled by this shim. */
int vortx_crash_signal_claim_marker(void);

#ifdef __cplusplus
}
#endif

#endif
