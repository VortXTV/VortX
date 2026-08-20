package com.vortx.android.player.subtitles

import com.vortx.android.model.MediaRef

/**
 * The one identity handoff shared by Android's add-on subtitle query, community pool, and offset memory.
 *
 * A catalog can begin with a TMDB-only [MediaRef]. Once the catalog edge resolves its IMDb id, every
 * subtitle consumer must use that exact replacement; using the original ref for one leg quietly partitions
 * the same episode into different subtitle namespaces.
 */
internal object SubtitlePlaybackIdentity {

    /** Returns [ref] with a validated resolved IMDb identity, or null when the result cannot identify media. */
    fun withResolvedImdb(ref: MediaRef, imdb: String?): MediaRef? {
        val normalized = imdb?.trim()?.lowercase()?.takeIf { Regex("tt\\d+").matches(it) } ?: return null
        return ref.copy(imdb = normalized)
    }

    /**
     * Builds the stable pool key and rip-scoped fingerprint from the information available at player load.
     * The fingerprint deliberately accepts missing runtime/frame-rate data; a late concrete duration can
     * refine a later fetch without changing the title identity.
     */
    fun poolIdentity(
        ref: MediaRef,
        durationMs: Long,
        frameRate: Double?,
        releaseName: String?,
    ): PoolIdentity? {
        val contentKey = SubtitlePoolContribution.contentKey(ref) ?: return null
        val durationSeconds = durationMs.takeIf { it > 0L }?.div(1_000.0)
        return PoolIdentity(
            contentKey = contentKey,
            fingerprint = SubtitlePoolContribution.fingerprint(frameRate, durationSeconds, releaseName),
        )
    }

    internal data class PoolIdentity(val contentKey: String, val fingerprint: String)
}
