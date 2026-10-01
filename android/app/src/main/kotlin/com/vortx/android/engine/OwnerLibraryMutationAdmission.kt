package com.vortx.android.engine

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.sync.LibraryTombstones
import com.vortx.android.sync.OwnerLibraryPublicationLease
import com.vortx.android.sync.OwnerWatchedIntentLease
import com.vortx.android.profile.UserProfile
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

/** Native/profile, VortX session, and durable tombstone ownership captured before the dispatcher hop. */
internal class OwnerLibraryMutationAdmission private constructor(
    private val fence: HistoryOwnerFence,
    private val permit: HistoryReadPermit,
    private val admit: ((() -> Boolean) -> Boolean),
    private val tombstones: LibraryTombstones,
    val publication: OwnerLibraryPublicationLease?,
    capturedWatchedIntents: OwnerWatchedIntentLease?,
) {
    val watchedIntents = capturedWatchedIntents.takeIf { permit.owner.profileId == UserProfile.OWNER_ID && permit.owner.usesEngineHistory }
    fun requireCurrent() {
        check(fence.readIsCurrent(permit) && admit { true }) { "Library owner changed. Try again." }
    }

    fun <T> mutate(block: (ContinueWatchingOwner, LibraryTombstones) -> T): T =
        fence.mutate(expectedOwner = permit.owner) { owner ->
            var result: T? = null
            check(admit { result = block(owner, tombstones); true }) { "Library account changed. Try again." }
            check(admit { true }) { "Library account changed. Try again." }
            @Suppress("UNCHECKED_CAST")
            result as T
        }

    companion object {
        fun capture(
            fence: HistoryOwnerFence,
            admit: ((() -> Boolean) -> Boolean)?,
            tombstones: () -> LibraryTombstones,
            publication: OwnerLibraryPublicationLease? = null,
            watchedIntents: OwnerWatchedIntentLease? = null,
        ): OwnerLibraryMutationAdmission {
            val accountAdmission = checkNotNull(admit) { "Library account is unavailable. Try again." }
            val permit = checkNotNull(fence.captureRead()) { "History owner is changing. Try again." }
            return OwnerLibraryMutationAdmission(fence, permit, accountAdmission, tombstones(), publication, watchedIntents).also { it.requireCurrent() }
        }
    }
}

/** This ordering is intentional: capture runs in the caller, before withContext can enqueue anything. */
internal suspend fun <T> withOwnerLibraryMutationAdmission(
    dispatcher: CoroutineDispatcher,
    capture: () -> OwnerLibraryMutationAdmission,
    operation: suspend (OwnerLibraryMutationAdmission) -> T,
): T {
    val admission = capture()
    return withContext(dispatcher) {
        admission.requireCurrent()
        operation(admission)
    }
}
