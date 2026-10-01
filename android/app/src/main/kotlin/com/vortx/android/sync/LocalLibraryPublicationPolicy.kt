package com.vortx.android.sync

/** Postconditions for the exact target action, after the lease proved absence or prior full-row ownership. */
internal object LocalLibraryPublicationPolicy {
    private fun pristine(row: VortXSyncDoc.OwnerLibraryItem): Boolean =
        row.timeOffsetMs == 0L && row.durationMs == 0L && row.watched.isNullOrEmpty() &&
            (row.timesWatched ?: 0) == 0L && row.currentVideoWatched != true && row.wholeTitleWatched != true

    fun membershipAdded(before: VortXSyncDoc.OwnerLibraryItem?, after: VortXSyncDoc.OwnerLibraryItem): Boolean =
        !after.removed && if (before == null) pristine(after) && after.videoId == null else sameExceptMembershipAndClock(before, after)

    fun playerLoaded(video: String?): (VortXSyncDoc.OwnerLibraryItem?, VortXSyncDoc.OwnerLibraryItem) -> Boolean = { before, after ->
        if (before == null) pristine(after) && (after.videoId == null || after.videoId == video)
        else after.name == before.name && after.poster == before.poster && after.watched == before.watched &&
            after.timesWatched == before.timesWatched && after.lastWatched == before.lastWatched &&
            (after.videoId == before.videoId || after.videoId == video) &&
            after.timeOffsetMs in listOf(0L, before.timeOffsetMs) && after.durationMs in listOf(0L, before.durationMs)
    }

    fun removed(before: VortXSyncDoc.OwnerLibraryItem?, after: VortXSyncDoc.OwnerLibraryItem): Boolean =
        before != null && after.removed && sameExceptMembershipAndClock(before, after)

    private fun sameExceptMembershipAndClock(before: VortXSyncDoc.OwnerLibraryItem, after: VortXSyncDoc.OwnerLibraryItem) =
        after.copy(removed = before.removed, nativeEventEpochMs = before.nativeEventEpochMs, eventEpochMs = before.eventEpochMs) == before

    fun progress(video: String?, position: Long, duration: Long): (VortXSyncDoc.OwnerLibraryItem?, VortXSyncDoc.OwnerLibraryItem) -> Boolean = { before, after ->
        after.videoId == video && after.timeOffsetMs == position && after.durationMs == duration && after.lastWatched != null &&
            (before != null || (after.watched.isNullOrEmpty() && (after.timesWatched ?: 0) <= 1))
    }

    fun watched(expected: Boolean): (VortXSyncDoc.OwnerLibraryItem?, VortXSyncDoc.OwnerLibraryItem) -> Boolean = { before, after ->
        if (before == null) {
            // A first movie mark has no inherited episode bitfield. Series first marks remain withheld
            // unless membership was already proven; we cannot validate an arbitrary encoded episode set.
            after.type == "movie" && !after.removed && after.lastWatched == null && after.timeOffsetMs == 0L && after.durationMs == 0L &&
                after.videoId in listOf(null, after.metaId) && after.watched.isNullOrEmpty() &&
                after.wholeTitleWatched == expected && (after.timesWatched ?: 0) == (if (expected) 1L else 0L) &&
                (after.currentVideoWatched != true || expected)
        } else after.name == before.name && after.poster == before.poster && after.videoId == before.videoId &&
            after.timeOffsetMs == before.timeOffsetMs && after.durationMs == before.durationMs && after.lastWatched == before.lastWatched &&
            after.removed == before.removed
    }
}
