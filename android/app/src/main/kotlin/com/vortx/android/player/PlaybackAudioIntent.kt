package com.vortx.android.player

/** Missing/sentinel metadata expresses no cross-file language preference. */
internal fun playbackAudioLanguage(value: String?): String? {
    val raw = value?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
    if (raw.substringBefore('-').substringBefore('_') in setOf("und", "unknown")) return null
    return TrackSelector.canonical(raw).takeIf { it.isNotBlank() }
}

/** User intent across files; engine-local track identifiers are deliberately not retained. */
data class PlaybackAudioIntent(val language: String?, val role: Role) {
    enum class Role { MAIN, COMMENTARY, DESCRIPTION }

    fun matchingTracks(tracks: List<PlayerTrack>): List<PlayerTrack> = tracks.filter {
        TrackSelector.matches(it.lang, language) && roleOf(it) == role
    }

    companion object {
        fun fromTrack(track: PlayerTrack): PlaybackAudioIntent =
            PlaybackAudioIntent(playbackAudioLanguage(track.lang), roleOf(track))

        private fun roleOf(track: PlayerTrack): Role {
            val title = track.title.lowercase()
            return when {
                "commentary" in title -> Role.COMMENTARY
                "description" in title || "descriptive" in title || "narration" in title -> Role.DESCRIPTION
                else -> Role.MAIN
            }
        }
    }
}
