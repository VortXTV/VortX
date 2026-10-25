package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.model.MediaType
import com.vortx.android.profile.UserProfile

/** One in-memory Library Play intent. A consumed intent still fences its unresolved source result. */
internal data class RandomTitlePlayRequest(
    val type: MediaType,
    val id: String,
    val owner: ContinueWatchingOwner,
    val profile: UserProfile,
    val detailGeneration: Long,
    val consumed: Boolean = false,
) {
    fun isCurrent(
        currentOwner: ContinueWatchingOwner,
        currentProfile: UserProfile?,
        needsPicker: Boolean,
        currentType: MediaType?,
        currentId: String?,
        currentDetailGeneration: Long,
    ): Boolean = !needsPicker && currentProfile != null &&
        profile == currentProfile && owner.profileId == profile.id && owner == currentOwner &&
        id.isNotBlank() && (type == MediaType.MOVIE || type == MediaType.SERIES) &&
        type == currentType && id == currentId && detailGeneration == currentDetailGeneration

    /** Consumption is a one-shot UI flag, not a new route authority. Clearing the intent is revocation. */
    fun sameIntent(other: RandomTitlePlayRequest?): Boolean = other != null &&
        copy(consumed = false) == other.copy(consumed = false)
}
