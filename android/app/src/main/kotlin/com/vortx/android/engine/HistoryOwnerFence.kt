package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.profile.ContinueWatchingOwnerGate

/** Immutable permission to read one history owner's state outside the process-wide owner monitor. */
internal data class HistoryReadPermit(
    val owner: ContinueWatchingOwner,
)

/**
 * Serializes history writes and validates reads against the same owner revision used by profile and
 * account transitions. The repository supplies the live owner and route/principal validator so this
 * class stays free of Android and native dependencies and can be exercised with hostile concurrency.
 */
internal class HistoryOwnerFence(
    private val captureOwner: (revision: Long) -> ContinueWatchingOwner,
    private val ownerRouteMatches: (ContinueWatchingOwner) -> Boolean,
    private val transitionInProgress: () -> Boolean,
) {
    fun captureRead(): HistoryReadPermit? = ContinueWatchingOwnerGate.serialized { revision ->
        if (transitionInProgress()) return@serialized null
        val owner = captureOwner(revision)
        if (!ownerRouteMatches(owner)) return@serialized null
        HistoryReadPermit(owner)
    }

    fun readIsCurrent(permit: HistoryReadPermit): Boolean =
        ContinueWatchingOwnerGate.serialized { revision ->
            !transitionInProgress() &&
                captureOwner(revision) == permit.owner &&
                ownerRouteMatches(permit.owner)
        }

    fun <T> mutate(
        expectedOwner: ContinueWatchingOwner? = null,
        block: (ContinueWatchingOwner) -> T,
    ): T = ContinueWatchingOwnerGate.serialized { revision ->
        check(!transitionInProgress()) { "History account transition is in progress." }
        val owner = captureOwner(revision)
        check(expectedOwner == null || owner == expectedOwner) { "History owner changed." }
        check(ownerRouteMatches(owner)) { "History owner or account principal changed." }
        val result = block(owner)
        check(captureOwner(revision) == owner && ownerRouteMatches(owner)) { "History owner changed." }
        result
    }
}
