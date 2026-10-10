package com.vortx.android.player

/** User intent across files; engine-local track identifiers are deliberately not retained. */
data class PlaybackAudioIntent(val language: String?, val role: Role) {
    enum class Role { MAIN, COMMENTARY, DESCRIPTION }

    fun matchingTracks(tracks: List<PlayerTrack>): List<PlayerTrack> = tracks.filter {
        TrackSelector.matches(it.lang, language) && roleOf(it) == role
    }

    companion object {
        fun fromTrack(track: PlayerTrack): PlaybackAudioIntent =
            PlaybackAudioIntent(track.lang?.trim()?.lowercase()?.takeIf { it.isNotBlank() }, roleOf(track))

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
