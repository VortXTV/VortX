package com.vortx.android.integrations

/** Compatibility entry point for the sign-in refresh. All rating state now has an exact session owner. */
internal object TraktRatingsSync {
    suspend fun sync(): Int {
        val owner = PersonalRatings.controller.owner(RatingProvider.TRAKT) ?: return 0
        return if (PersonalRatings.controller.refresh(owner)) 1 else 0
    }
}
