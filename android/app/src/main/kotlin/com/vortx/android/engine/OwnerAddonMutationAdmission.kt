package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.sync.AddonPublicationLease
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Capture before manifest IO; the delayed result cannot adopt a replacement account or native owner. */
internal class OwnerAddonMutationAdmission private constructor(
    private val fence: HistoryOwnerFence,
    private val permit: HistoryReadPermit,
    private val admit: ((() -> Boolean) -> Boolean),
    val publication: AddonPublicationLease?,
) {
    fun <T> mutate(block: (ContinueWatchingOwner) -> T): T = fence.mutate(expectedOwner = permit.owner) { owner ->
        var result: T? = null
        check(admit { result = block(owner); true }) { "Add-on account changed. Try again." }
        check(admit { true }) { "Add-on account changed. Try again." }
        @Suppress("UNCHECKED_CAST")
        result as T
    }

    companion object {
        fun capture(fence: HistoryOwnerFence, admit: ((() -> Boolean) -> Boolean)?, publication: AddonPublicationLease?): OwnerAddonMutationAdmission {
            val admission = checkNotNull(admit) { "Add-on account is unavailable. Try again." }
            val permit = checkNotNull(fence.captureRead()) { "Native owner is changing. Try again." }
            check(fence.readIsCurrent(permit) && admission { true }) { "Add-on owner changed. Try again." }
            return OwnerAddonMutationAdmission(fence, permit, admission, publication)
        }
    }
}

internal suspend fun <T> performOwnedAddonInstall(
    capture: () -> OwnerAddonMutationAdmission,
    fetch: suspend () -> T,
    install: (OwnerAddonMutationAdmission, T) -> Unit,
) {
    val admission = capture()
    val manifest = fetch()
    install(admission, manifest)
}

internal suspend fun <T> withOwnerAddonMutationAdmission(
    dispatcher: CoroutineDispatcher,
    capture: () -> OwnerAddonMutationAdmission,
    operation: (OwnerAddonMutationAdmission) -> T,
): T {
    val admission = capture()
    return withContext(dispatcher) { operation(admission) }
}
