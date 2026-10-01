package com.vortx.android.integrations

import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.Episode

/** Pure identity and async-ownership rules for the user-initiated detail check-in. */
internal object TraktManualCheckInPolicy {
    private var inFlightOwner: Owner? = null
    sealed interface Target {
        data class Movie(val id: String) : Target
        data class EpisodeTarget(val id: String, val season: Int, val episode: Int) : Target
    }

    data class Owner(
        val accountEpoch: Long,
        val profileId: String,
        val titleId: String,
        val target: Target,
    )

    enum class RequestState { IDLE, IN_FLIGHT, SUCCESS, CONFLICT, FAILURE }

    fun target(detail: MetaDetail, primaryEpisode: Episode?): Target? {
        val id = normalizeId(detail.id) ?: return null
        if (detail.type == MediaType.MOVIE) return Target.Movie(id)
        if (detail.type != MediaType.SERIES) return null
        val selected = primaryEpisode ?: return null
        // Season zero is valid only when the selected primary episode explicitly carries it (specials).
        if (selected.season < 0 || selected.episode < 1) return null
        return Target.EpisodeTarget(id, selected.season, selected.episode)
    }

    fun canOffer(configured: Boolean, optedIn: Boolean, ownerProfile: Boolean, connected: Boolean,
                 target: Target?): Boolean = configured && optedIn && ownerProfile && connected && target != null

    @Synchronized
    fun begin(state: RequestState, owner: Owner): RequestState? {
        if (state == RequestState.IN_FLIGHT || inFlightOwner != null) return null
        inFlightOwner = owner
        return RequestState.IN_FLIGHT
    }

    @Synchronized
    fun finish(owner: Owner) {
        if (inFlightOwner == owner) inFlightOwner = null
    }

    fun completion(current: Owner, requestOwner: Owner, result: RequestState): RequestState? =
        result.takeIf { current == requestOwner && result != RequestState.IN_FLIGHT && result != RequestState.IDLE }

    private fun normalizeId(raw: String): String? {
        val value = raw.trim()
        if (value.matches(Regex("tt\\d{6,}"))) return value
        val tmdb = Regex("(?i)^tmdb:(?:(?:movie|tv):)?(\\d+)$").matchEntire(value)?.groupValues?.get(1)
        return tmdb?.toLongOrNull()?.takeIf { it > 0 }?.toString()?.let { "tmdb:$it" }
    }
}
