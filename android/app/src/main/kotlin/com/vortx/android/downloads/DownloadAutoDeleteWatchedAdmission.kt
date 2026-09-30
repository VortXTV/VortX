package com.vortx.android.downloads

/**
 * Keeps a setting change and the reclaim admission decision on the manager's existing lifecycle lock. Once an OFF
 * write wins that lock, no later admission can begin a media transaction. An already admitted reclaim intentionally
 * completes before a later toggle obtains the same lock, rather than interleaving file/index mutations.
 */
internal object DownloadAutoDeleteWatchedAdmission {
    fun setEnabled(lock: Any, enabled: Boolean, persist: (Boolean) -> Unit) {
        synchronized(lock) { persist(enabled) }
    }

    fun <T> admit(
        lock: Any,
        isEnabled: () -> Boolean,
        disabled: () -> T,
        reclaim: () -> T,
    ): T = synchronized(lock) {
        if (isEnabled()) reclaim() else disabled()
    }
}
