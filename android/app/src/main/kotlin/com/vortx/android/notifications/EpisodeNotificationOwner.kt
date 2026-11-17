package com.vortx.android.notifications

import com.vortx.android.data.ContinueWatchingOwner
import java.security.MessageDigest

/** The mounted checkpoint scope and selected profile are stable across process death. */
internal data class EpisodeNotificationOwner private constructor(val scopeDigest: String, val profileId: String) {
    private val eventPrefix: String get() = "vortx.newepisode.v2/$scopeDigest/$profileId/"

    fun matchesLibrary(owner: ContinueWatchingOwner?): Boolean =
        owner != null && owner.accountSlot == scopeDigest && owner.profileId == profileId

    fun eventKey(seriesId: String, airEpochMillis: Long): String = "$eventPrefix$airEpochMillis/$seriesId"

    /** Keep the raw checkpoint scope and profile out of Android's notification tag. */
    fun notificationTag(seriesId: String, airEpochMillis: Long): String? {
        if (seriesId.isBlank() || airEpochMillis <= 0L) return null
        val event = eventKey(seriesId, airEpochMillis).toByteArray(Charsets.UTF_8)
        val digest = MessageDigest.getInstance("SHA-256").digest(event).joinToString("") { "%02x".format(it) }
        return "vortx.newepisode/$digest"
    }

    /** Keep an existing attempt that became due while its exact owner was unavailable. */
    fun retainsWork(
        tags: Set<String>,
        eligibleSeries: Set<String>,
        desiredEvents: Set<String>,
        nowMillis: Long,
    ): Boolean {
        val event = tags.singleOrNull { it.startsWith(eventPrefix) } ?: return false
        val episode = event.removePrefix(eventPrefix)
        val separator = episode.indexOf('/')
        if (separator <= 0) return false
        val airTime = episode.substring(0, separator).toLongOrNull()?.takeIf { it > 0 } ?: return false
        val series = episode.substring(separator + 1)
        return series in eligibleSeries && (airTime <= nowMillis || event in desiredEvents)
    }

    companion object {
        private val digestPattern = Regex("[0-9a-f]{64}")

        /** The profile is checked against a real roster separately, at capture and at delivery. */
        fun parse(scopeDigest: String?, profileId: String?): EpisodeNotificationOwner? {
            if (scopeDigest == null || !digestPattern.matches(scopeDigest) || profileId.isNullOrBlank() ||
                '/' in profileId || '\u0000' in profileId) return null
            return EpisodeNotificationOwner(scopeDigest, profileId)
        }
    }
}
