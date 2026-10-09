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
    private val transferWitnesses = mutableSetOf<TransferWitness>()
    private var admittedTransfer: TransferWitness? = null

    /** A transfer may admit only a synchronous, explicitly supplied native projection transition. */
    internal class TransferWitness internal constructor() {
        @Volatile internal var current = true
        fun isCurrent(): Boolean = current
        fun retire() = synchronized(monitor) { current = false; transferWitnesses.remove(this); Unit }
        fun project(isCurrent: () -> Boolean, action: () -> Unit): Boolean = synchronized(monitor) {
            if (!current || !isCurrent()) return@synchronized false
            val previous = admittedTransfer
            admittedTransfer = this
            try { action(); current && isCurrent() } finally { admittedTransfer = previous }
        }
    }

    internal fun captureTransferWitness(): TransferWitness = synchronized(monitor) {
        TransferWitness().also(transferWitnesses::add)
    }

    fun <T> serialized(block: (revision: Long) -> T): T = synchronized(monitor) {
        block(revision)
    }

    /**
     * Run one ownership transition under the same monitor as snapshot reads and dismissals. [capture]
     * executes before the first mutation, and the revision advances unconditionally when [block] exits,
     * including when the old and new public fallback bindings happen to compare equal.
     */
    fun <B, T> transition(capture: () -> B, block: (before: B) -> T): T = synchronized(monitor) {
        // A projection receipt admits at most this one transition. Callbacks nested inside it
        // receive no exemption: a foreign transition permanently retires the witness.
        val acceptedProjection = admittedTransfer
        admittedTransfer = null
        val before = capture()
        try {
            block(before)
        } finally {
            advanceLocked(acceptedProjection)
        }
    }

    /** Must be called from ownership-transition code. Synchronized is re-entrant for callers already gated. */
    fun advance(): Long = synchronized(monitor) {
        advanceLocked()
    }

    private fun advanceLocked(acceptedProjection: TransferWitness? = null): Long {
        check(revision < Long.MAX_VALUE) { "Continue Watching owner revision exhausted." }
        transferWitnesses.removeAll { witness ->
            (witness !== acceptedProjection).also { if (it) witness.current = false }
        }
        return ++revision
    }
}
