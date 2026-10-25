package com.vortx.android.ui.randompick

import com.vortx.android.data.ContinueWatchingOwner
import com.vortx.android.profile.UserProfile

/** Actual immutable adapter witness: a fallback profile ID is never an admitted selection. */
internal data class RandomEpisodeAccess(
    val owner: ContinueWatchingOwner,
    val profile: UserProfile,
    val effectiveMetaId: String,
) {
    companion object {
        fun capture(
            owner: ContinueWatchingOwner,
            profile: UserProfile?,
            needsPicker: Boolean,
            effectiveMetaId: String,
            sourceProfileId: String,
            routeAdmitted: Boolean,
        ): RandomEpisodeAccess? {
            if (profile == null || needsPicker || !routeAdmitted || effectiveMetaId.isBlank()) return null
            if (owner.profileId != profile.id || sourceProfileId != profile.id) return null
            return RandomEpisodeAccess(owner, profile, effectiveMetaId)
        }
    }
}
