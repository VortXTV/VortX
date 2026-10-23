package com.vortx.android.profile

/**
 * Process-wide serialization point for profile/account ownership of Continue Watching.
 *
 * Profile selection, owner-token capture, Home snapshot reads, and dismiss dispatch all use this monitor.
 * That makes the owner check and the mutation one atomic operation instead of a check-then-act race. The
 * revision is advanced while the monitor is held whenever an owning profile or account session changes.
 */
internal object ContinueWatchingOwnerGate {
    private val monitor = Any()
    private var revision = 0L

    fun <T> serialized(block: (revision: Long) -> T): T = synchronized(monitor) {
        block(revision)
    }

    /**
     * Run one ownership transition under the same monitor as snapshot reads and dismissals. [capture]
     * executes before the first mutation, and the revision advances unconditionally when [block] exits,
     * including when the old and new public fallback bindings happen to compare equal.
     */
    fun <B, T> transition(capture: () -> B, block: (before: B) -> T): T = synchronized(monitor) {
        val before = capture()
        try {
            block(before)
        } finally {
            advanceLocked()
        }
    }

    /** Must be called from ownership-transition code. Synchronized is re-entrant for callers already gated. */
    fun advance(): Long = synchronized(monitor) {
        advanceLocked()
    }

    private fun advanceLocked(): Long {
        check(revision < Long.MAX_VALUE) { "Continue Watching owner revision exhausted." }
        return ++revision
    }
}
