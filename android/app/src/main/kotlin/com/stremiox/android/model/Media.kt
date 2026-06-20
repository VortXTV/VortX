package com.stremiox.android.model

/// Domain models for the Android + Android TV client. These mirror the shapes the shared
/// stremio-core engine returns (and the iOS/tvOS apps already render via `CoreMetaItem`,
/// `CoreVideo`, `CoreStream`, `CoreStreamSourceGroup`), so the Compose UI is built against them now
/// and the real engine plugs in behind [com.stremiox.android.data.CatalogRepository] without any UI
/// changes.

enum class MediaType(val label: String, val id: String) {
    MOVIE("Movie", "movie"),
    SERIES("Series", "series"),
    CHANNEL("Channel", "channel"),
    TV("TV", "tv");

    companion object {
        fun fromId(id: String): MediaType = when (id.lowercase()) {
            "movie" -> MOVIE
            "series" -> SERIES
            "channel" -> CHANNEL
            "tv" -> TV
            else -> MOVIE
        }
    }
}

/// A single catalog entry (movie, series, etc.). [poster] is a URL once the engine is wired; until
/// then it is null and the UI renders a deterministic brand-tinted placeholder card.
data class MetaItem(
    val id: String,
    val type: MediaType,
    val name: String,
    val poster: String? = null,
    val year: String? = null,
    val description: String? = null,
)

/// A named row of items, e.g. "Continue Watching" or an add-on catalog like "Cinemeta - Popular".
data class Catalog(
    val id: String,
    val title: String,
    val items: List<MetaItem>,
)

/// One episode of a series, mirroring the engine's `CoreVideo`. [season]/[episode] drive the season
/// selector and episode list on the detail page once series detail lands.
data class Episode(
    val id: String,
    val title: String,
    val season: Int,
    val episode: Int,
    val overview: String? = null,
    val thumbnail: String? = null,
    val released: String? = null,
)

/// Full meta detail, mirroring the engine's `meta_details.meta` (`CoreMetaItem`): the cinematic
/// [background], the metadata row ([imdbRating]/[releaseInfo]/[runtime]/[genres]) the tvOS detail
/// page leads with, and (for series) the [videos] episode list.
data class MetaDetail(
    val id: String,
    val type: MediaType,
    val name: String,
    val poster: String? = null,
    val background: String? = null,
    val description: String? = null,
    val releaseInfo: String? = null,
    val runtime: String? = null,
    val imdbRating: String? = null,
    val genres: List<String> = emptyList(),
    val videos: List<Episode> = emptyList(),
)

/// A single playable source for a title, mirroring the engine's `CoreStream`. The UI shows
/// [addon] (which add-on returned it), the human [title]/[description] the add-on wrote, and the
/// [quality] tier the ranking derived. [isTorrent] flips the row icon and adds a TORRENT badge,
/// matching the tvOS source list.
data class StreamSource(
    val id: String,
    val addon: String,
    val title: String,
    val description: String? = null,
    val quality: String? = null,
    val isTorrent: Boolean = false,
)

/// Sources grouped by the add-on that returned them, mirroring `CoreStreamSourceGroup`. The detail
/// page renders one labeled block per group, best source first.
data class StreamGroup(
    val addon: String,
    val streams: List<StreamSource>,
)

/// A resolved, directly-playable handle for the player. The engine turns a [StreamSource] (which may
/// be a torrent infohash, a debrid lock, or an HTTP link) into one of these: a concrete [url] the
/// player can open plus the chrome metadata. For torrents the engine first hands the magnet to the
/// in-process streaming server and returns the server's local HLS/progressive URL here, so the player
/// only ever sees a real URL and never has to know how it was produced.
data class Playable(
    val url: String,
    /// What to show in the player title bar (the human source title, falling back to the meta name).
    val title: String,
    /// True when the engine resolved this through the streaming server (torrent/debrid), so the player
    /// can show a "buffering from source" affordance distinct from a plain network stall.
    val viaStreamingServer: Boolean = false,
    /// Resume position in milliseconds from per-profile watch history, or 0 to start from the top.
    val startPositionMs: Long = 0L,
)
