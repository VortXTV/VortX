package com.vortx.android.player

/**
 * Pure revocation publication, NOT an owner-pinning lease or global check-to-call transaction.
 * Real owner writers bracket their existing synchronous publication. No native calls, callbacks,
 * scheduling or waits occur here; a mounted player observes retirement and releases outside locks.
 */
internal object PlaybackOwnerEpoch {
    private val lock = Any()
    private val transitions = mutableSetOf<Any>()
    private var current: PlaybackOwnerToken? = PlaybackOwnerToken()

    /** Capture BEFORE reading the manager/availability/host identity; never substitute a later token. */
    fun capture(): PlaybackOwnerToken? = synchronized(lock) { current }

    /** State-only final proof of that same candidate inside authenticated original-owner admission. */
    fun isCurrent(original: PlaybackOwnerToken): Boolean = synchronized(lock) {
        current === original && original.isActive
    }

    fun <T> transition(mutation: () -> T): T {
        val ticket = synchronized(lock) {
            current?.retire()
            current = null
            Any().also(transitions::add)
        }
        return try {
            mutation() // No epoch lock is owned across the original owner's operation.
        } finally {
            synchronized(lock) {
                check(transitions.remove(ticket)) { "Playback owner transition closed twice" }
                if (transitions.isEmpty()) current = PlaybackOwnerToken()
            }
        }
    }

    /** A native authority publication already serialized by its existing owner boundary. */
    fun invalidate() = transition { }
}
