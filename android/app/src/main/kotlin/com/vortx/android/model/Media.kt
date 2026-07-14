package com.vortx.android.model

/// Domain models for the Android + Android TV client. These mirror the shapes the shared
/// stremio-core engine returns (and the iOS/tvOS apps already render via `CoreMetaItem`,
/// `CoreVideo`, `CoreStream`, `CoreStreamSourceGroup`), so the Compose UI is built against them now
/// and the real engine plugs in behind [com.vortx.android.data.CatalogRepository] without any UI
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
/// then it is null and the UI renders a deterministic brand-tinted placeholder card. [progress]
/// (0f..1f, null = not in progress) comes from the library's timeOffset/duration on Continue
/// Watching items and drives PosterCard's accent progress track.
data class MetaItem(
    val id: String,
    val type: MediaType,
    val name: String,
    val poster: String? = null,
    val year: String? = null,
    val description: String? = null,
    val progress: Float? = null,
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
///
/// S05 additions (mirroring `CoreMetaDetails`/`CoreMetaItem`): [logo] for the hero logo-or-title
/// slot, [cast]/[directors]/[writers] credits (read from the same `links` array as [genres], the
/// engine's own categorized-link convention -- no extra network call), [libraryItem] (the engine's
/// saved library entry for THIS title, driving Add-to-Library state + resume position), and
/// [watchedVideoIds] (episode ids the engine's WatchedBitField marks watched, injected by
/// `TvosModel::meta_details_json` in `core/src/model.rs` since the bitfield itself is
/// `#[serde(skip_serializing)]` -- see that function's doc comment).
data class MetaDetail(
    val id: String,
    val type: MediaType,
    val name: String,
    val poster: String? = null,
    val background: String? = null,
    val logo: String? = null,
    val description: String? = null,
    val releaseInfo: String? = null,
    val runtime: String? = null,
    val imdbRating: String? = null,
    val genres: List<String> = emptyList(),
    val cast: List<String> = emptyList(),
    val directors: List<String> = emptyList(),
    val writers: List<String> = emptyList(),
    val videos: List<Episode> = emptyList(),
    val libraryItem: LibraryItemInfo? = null,
    val watchedVideoIds: Set<String> = emptySet(),
)

/// The engine's saved library entry for the open title (`meta_details.libraryItem`, a `LibraryItem`
/// mirroring the Apple `CoreCWItem` shape). Drives three things on Detail: whether the Add-to-Library
/// chip reads "saved" ([removed]/[temp] both false), the movie-level watched dot ([timesWatched] > 0,
/// matching Apple's `isWatched`), and the series resume target ([videoId]/[timeOffsetMs] against
/// [MetaDetail.watchedVideoIds], see `DetailViewModel.primaryEpisode`).
data class LibraryItemInfo(
    val id: String?,
    val removed: Boolean,
    val temp: Boolean,
    val videoId: String?,
    val timeOffsetMs: Long,
    val durationMs: Long,
    val timesWatched: Int,
) {
    /// Present in the library proper (not a bare watched-marker temp entry, not soft-removed).
    val savedToLibrary: Boolean get() = !removed && !temp

    /// Movie-level watched flag (a movie has no per-video ticks), matching Apple's
    /// `CoreCWItem.isWatched` (`state.timesWatched > 0`).
    val isWatched: Boolean get() = timesWatched > 0

    /// 0f..1f watch progress for a title with no episodes (a movie), or null when unknown/zero -- the
    /// same math as [com.vortx.android.engine.EngineState]'s Continue Watching progress.
    val progress: Float?
        get() {
            if (durationMs <= 0L || timeOffsetMs <= 0L) return null
            return (timeOffsetMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
        }
}

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
    /// True when [url] is a loopback URL served by the in-process streaming server (a resolved torrent).
    /// The [PlayerEngineRouter] keeps torrents on libmpv (ExoPlayer cannot replay the torrent warm-up),
    /// and the mpv engine sizes its read-ahead down for a local stream, mirroring the Apple engine.
    val isTorrent: Boolean = false,
    /// Dolby Vision, flagged by stream ranking at selection time (a heuristic text parse, the only DV
    /// signal available pre-play). Routes to the ExoPlayer engine so its [DefaultRenderersFactory] can
    /// do the DV -> HEVC/AVC/AV1 codec fallback the panel actually supports (libmpv/gpu-next only
    /// tone-maps DV to SDR on Android). See [PlayerEngineRouter].
    val isDolbyVision: Boolean = false,
    /// Dolby Atmos / bitstream-passthrough audio, flagged at selection time. Routes to the ExoPlayer
    /// engine, whose [DefaultAudioSink] negotiates E-AC3-JOC/TrueHD passthrough against the device's
    /// [AudioCapabilities]; mpv's Android AO decodes to PCM instead. See [PlayerEngineRouter].
    val isAtmos: Boolean = false,
    /// Per-stream HTTP request headers (Stremio `behaviorHints.proxyHeaders`): some add-ons front CDNs
    /// that require a specific Referer or browser User-Agent. Applied by whichever engine plays the
    /// stream (mpv via `http-header-fields`, ExoPlayer via the data-source factory).
    val headers: Map<String, String> = emptyMap(),
    /// External sidecar subtitle URLs to mount alongside the video (add-on resolved subtitles). mpv
    /// mounts them via `sub-add`; the ExoPlayer path can attach them as side-loaded text tracks.
    val externalSubtitles: List<String> = emptyList(),
)
