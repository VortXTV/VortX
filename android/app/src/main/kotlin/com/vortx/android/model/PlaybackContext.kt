package com.vortx.android.model

import com.vortx.android.integrations.buildMediaRef

/**
 * Immutable identity for ONE LOCAL playback session (an offline download played from disk), bound
 * BEFORE any consumer may act on it. This is the Android port of Apple's `PlaybackMeta` play-from-local
 * rebuild (`app/SourcesShared/DownloadModels.swift` `record.playbackMeta`) plus the owner binding Apple
 * gets implicitly from its per-profile engine routing.
 *
 * WHY IT EXISTS (audit AND-DL-01): a local [Playable] used to carry no media identity at all, so
 * every progress / watched / scrobble / auto-next decision fell back to whatever title the resident
 * engine or detail surface happened to be holding -- stream A, then play downloaded B, and A's row
 * moved. Every identity-bearing decision for a local session MUST derive from this context (or see
 * no identity at all), never from ambient state.
 *
 * Platform-neutral by design: plain immutable values only, so a later round can hand it to the
 * playback-session seam (`beginPlaybackSession`-style) without reshaping it.
 *
 * @property owner Who is watching, captured AT PLAY TIME (a download index is device-local and not
 *   per-profile). [Owner.usesEngineHistory] mirrors `ProfileStore.activeUsesEngineHistory`: true for
 *   the owner / own-account profiles whose watch state lives in the engine library, false for an
 *   overlay profile with its own PRIVATE history -- exactly the repository's HistoryRoute split.
 * @property contentId The movie/series id (the libraryItem `_id`). For a movie this equals [videoId];
 *   for an episode it is the series id. Same value the streaming play path resolves against.
 * @property videoId The movie id, or `imdbId:season:episode` for an episode.
 * @property type "movie" | "series" (matching the streaming episode play path).
 * @property season 1-based season for an episode; null for a movie.
 * @property episode 1-based episode number for an episode; null for a movie.
 * @property title Display title of the item itself (episode rows carry the show name in
 *   [MediaRef.title] parity terms, so episodes pass the SHOW name here, matching the streaming path).
 * @property poster Artwork URL for Continue Watching / now-playing parity; null when the record has none.
 * @property provenance Immutable snapshot of HOW the bytes were obtained, kept so diagnostics never
 *   depend on ambient download-index state that can mutate mid-play.
 */
data class PlaybackContext(
    val owner: Owner,
    val contentId: String,
    val videoId: String,
    val type: String,
    val season: Int?,
    val episode: Int?,
    val title: String,
    val poster: String?,
    val provenance: Provenance,
) {
    /**
     * Who is watching. [usesEngineHistory] mirrors `ProfileStore.activeUsesEngineHistory` (true =
     * engine/account history route, false = per-profile overlay history route).
     */
    data class Owner(
        val profileId: String,
        val usesEngineHistory: Boolean,
    )

    /** How the downloaded bytes were obtained. Identity-grade facts only; never a raw URL or token. */
    data class Provenance(
        /** Add-on / source label the download came from (`stream.name`); null on legacy records. */
        val sourceName: String?,
        /** Quality signature recorded at download time; null on legacy records. */
        val qualityText: String?,
        /** True when fetched torrent-to-disk (a finished download still plays from the LOCAL file). */
        val torrentFetched: Boolean,
        /**
         * Native-debrid capability ownership copied from the record (opaque identity + generation),
         * both null for direct/local and legacy records. Never an API key or token.
         */
        val debridOwnerIdentity: String?,
        val debridOwnerGeneration: Long?,
    )

    /** True when this context describes one episode of a series (movie-vs-episode payload shape). */
    val isSeriesEpisode: Boolean
        get() = type == "series" && season != null && episode != null

    /**
     * Stable MEDIA identity (no owner, no provenance): two contexts name the same title iff their
     * keys are equal. This is the key "only B changes" assertions compare against.
     */
    val identityKey: String
        get() = "$type|$contentId|$videoId"

    /**
     * Stable RESUME identity: the per-owner key under which THIS session's progress belongs. The
     * route tag mirrors the repository's history split (engine vs overlay), so an owner profile and
     * an overlay profile watching the same file keep separate resume lines, exactly as streamed
     * plays already do.
     */
    val resumeIdentity: String
        get() = "${owner.profileId}:${if (owner.usesEngineHistory) "engine" else "overlay"}:$videoId"

    /**
     * The scrobble/subtitle/skip/trickplay identity, derived through THE SAME [buildMediaRef] the
     * streaming path uses so a downloaded play and its streamed twin produce byte-equivalent refs
     * (imdb preferred, tmdb fallback, season/episode only for series). Null when the ids are not
     * resolvable (a kitsu-only catalog), in which case the player simply does not scrobble -- the
     * same fail-safe rule as a streamed play.
     */
    fun toMediaRef(): MediaRef? {
        val mediaType = MediaType.fromId(type)
        return buildMediaRef(
            type = mediaType,
            metaId = contentId,
            // Episode shape only; [buildMediaRef] reads just season/episode off it.
            episode = if (isSeriesEpisode) {
                Episode(id = videoId, title = "", season = season ?: 0, episode = episode ?: 0)
            } else {
                null
            },
            title = title,
            year = null,
        )
    }
}
