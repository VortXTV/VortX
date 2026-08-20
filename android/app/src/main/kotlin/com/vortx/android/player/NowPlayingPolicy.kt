package com.vortx.android.player

import com.vortx.android.model.Playable

/**
 * One item's identity + display metadata for the system Now-Playing surface (the Android media session
 * that drives the lockscreen / quick-settings media card, Bluetooth / headset displays, Android Auto and
 * the assistant). The Android port of Apple `NowPlayingItem` (app/SourcesShared/NowPlayingPolicy.swift).
 *
 * A plain value type with no media3 / Android types, so [NowPlayingPolicy] below stays a pure, testable
 * mapping exactly like Apple's.
 */
data class NowPlayingItem(
    /** The title line (an episode label for a series, the film name for a movie). */
    val title: String,
    /** The series name, when this is an episode. Null for a movie / one-off stream. */
    val showName: String? = null,
    val season: Int? = null,
    val episode: Int? = null,
    /** Poster / art URL, loaded off-thread and attached once. */
    val artworkUrl: String? = null,
    /** Live content has no meaningful duration or scrub position, so the system is told so explicitly. */
    val isLive: Boolean = false,
) {
    companion object {
        /**
         * Derive the Now-Playing item from a [Playable] + its [com.vortx.android.model.MediaRef]. Mirrors
         * how Apple's player fills `NowPlayingItem` from the same catalog identity: the episode title (else
         * the source title) is the primary line, the show name + SxxEyy the secondary line, the season the
         * album line. A movie carries no season/episode, so it never renders a bogus code.
         */
        fun from(playable: Playable): NowPlayingItem {
            val ref = playable.mediaRef
            val isSeries = ref?.isSeries == true
            // A series shows the EPISODE title; a movie shows the clean movie name. Both fall back to the
            // source title when the metadata title is missing.
            val title = if (isSeries) {
                playable.episodeTitle?.takeIf { it.isNotBlank() } ?: playable.title
            } else {
                ref?.title?.takeIf { it.isNotBlank() } ?: playable.title
            }
            return NowPlayingItem(
                title = title,
                showName = if (isSeries) ref?.title?.takeIf { it.isNotBlank() } else null,
                season = if (isSeries) ref?.season else null,
                episode = if (isSeries) ref?.episode else null,
                artworkUrl = playable.posterUrl,
                isLive = playable.isLive,
            )
        }
    }
}

/**
 * Every decision that shapes the system Now-Playing surface, kept pure so it is testable and identical to
 * Apple's. The Android port of Apple `NowPlayingPolicy` (app/SourcesShared/NowPlayingPolicy.swift): the
 * media session ([PlayerMediaSession]) is the thin media3 shell that applies these.
 */
object NowPlayingPolicy {

    /** The title line. Falls back to the show name, then the product name, so an EMPTY title never reads
     * as a broken card. Mirrors Apple `primaryTitle`. */
    fun primaryTitle(item: NowPlayingItem): String {
        val title = item.title.trim()
        if (title.isNotEmpty()) return title
        val show = (item.showName ?: "").trim()
        return show.ifEmpty { "VortX" }
    }

    /** The secondary (artist) line: the show name plus the episode code, the show dropped when the title
     * already carries it. Null when there is nothing to show. Mirrors Apple `secondaryLine`. */
    fun secondaryLine(item: NowPlayingItem): String? {
        val parts = mutableListOf<String>()
        val show = (item.showName ?: "").trim()
        if (show.isNotEmpty() && !item.title.contains(show, ignoreCase = true)) parts.add(show)
        episodeCode(item.season, item.episode)?.let { parts.add(it) }
        val line = parts.joinToString(" · ")
        return line.ifEmpty { null }
    }

    /** "S02E03" / "E03", or null when this is not an episode. Zero / negative numbers are treated as absent
     * (add-on metadata routinely carries 0 for "unknown"). Mirrors Apple `episodeCode`. */
    fun episodeCode(season: Int?, episode: Int?): String? {
        val ep = episode ?: return null
        if (ep <= 0) return null
        return if (season != null && season > 0) "S%02dE%02d".format(season, ep) else "E%02d".format(ep)
    }

    /** The album line: the season, when there is one. Never invented for a movie. Mirrors Apple `seasonLine`. */
    fun seasonLine(item: NowPlayingItem): String? {
        val season = item.season ?: return null
        if (season <= 0 || item.episode == null) return null
        return "Season $season"
    }

    /** The duration to publish, or null when there is none. A live stream deliberately publishes no
     * duration (a bogus scrubbable bar otherwise); a durationless VOD omits it until a real value lands.
     * Mirrors Apple `publishableDuration`. */
    fun publishableDurationMs(durationMs: Long, isLive: Boolean): Long? {
        if (isLive || durationMs <= 0L) return null
        return durationMs
    }

    /** Whether the system should be offered absolute scrubbing (the media-card progress drag / seek
     * commands). Live and durationless streams cannot honour it, so the commands stay disabled there
     * rather than accepting a drag the engine then ignores. Mirrors Apple `allowsScrubbing`. */
    fun allowsScrubbing(durationMs: Long, isLive: Boolean): Boolean =
        publishableDurationMs(durationMs, isLive) != null
}
