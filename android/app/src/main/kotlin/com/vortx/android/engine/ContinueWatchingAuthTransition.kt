package com.vortx.android.engine

import com.vortx.android.profile.ContinueWatchingOwnerGate

/**
 * Process-local lifecycle for native authentication. Every caller terminal, including timeout,
 * dispatch failure, and cancellation, closes only its own generation. Explicit sign-out may cancel
 * the current generation regardless of which caller owns it.
 */
internal class ContinueWatchingAuthTransition {
    @Volatile
    private var activeGeneration: Long? = null
    private var lastGeneration = 0L

    val inProgress: Boolean get() = activeGeneration != null

    fun begin(): Long = ContinueWatchingOwnerGate.serialized {
        check(activeGeneration == null) { "An account transition is already in progress." }
        check(lastGeneration < Long.MAX_VALUE) { "Auth transition generation exhausted." }
        val generation = ++lastGeneration
        activeGeneration = generation
        ContinueWatchingOwnerGate.advance()
        generation
    }

    fun finish(expectedGeneration: Long): Boolean =
        ContinueWatchingOwnerGate.serialized {
            val active = activeGeneration ?: return@serialized false
            if (expectedGeneration != active) return@serialized false
            activeGeneration = null
            ContinueWatchingOwnerGate.advance()
            true
        }

    fun cancelActive(): Boolean = ContinueWatchingOwnerGate.serialized {
        if (activeGeneration == null) return@serialized false
        activeGeneration = null
        ContinueWatchingOwnerGate.advance()
        true
    }
}
