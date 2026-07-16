package com.vortx.android.model

import java.time.Instant
import java.time.OffsetDateTime

/// Domain models for the Android + Android TV client. These mirror the shapes the shared
/// stremio-core engine returns (and the iOS/tvOS apps already render via `CoreMetaItem`,
/// `CoreVideo`, `CoreStream`, `CoreStreamSourceGroup`), so the Compose UI is built against them now
/// and the real engine plugs in behind [com.vortx.android.data.CatalogRepository] without any UI
/// changes.

/// A whole-seconds count to a compact timecode: "M:SS" under an hour, "H:MM:SS" past it. The shared
/// "resume 1:03" / "45:12" / "1:12:30" affordance on Continue Watching cards and the detail primary
/// button (mirrors Apple `resumeTimecode` in `CoreModels.swift`, itself mirroring the webapp's
/// `formatTime`). Returns null for non-positive input so callers can cleanly omit the badge / suffix
/// when there is nothing to resume.
fun resumeTimecode(seconds: Double): String? {
    if (!seconds.isFinite() || seconds < 1.0) return null
    val total = seconds.toInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}

/// The content types Stremio treats as Live TV (mirrors Apple `LiveTypes` in `CoreModels.swift`): the
/// same set the live surface, the live detail branch, and the player all agree on. Matched
/// CASE-INSENSITIVELY across the common variants (a "sport" / "Sports" / "live" / "linear" feed must
/// open in live mode). Exact tokens only, never substrings, so "tv" can't swallow "tvshow".
object LiveTypes {
    val all: Set<String> = setOf(
        "tv", "channel", "channels", "events", "event",
        "sport", "sports", "live", "linear", "iptv",
    )

    fun contains(type: String): Boolean = all.contains(type.lowercase())
}

/// Add-on ordering used by the #144 detail-meta pick (mirrors Apple `AddonTombstones.normalize` +
/// `CoreMetaDetails.meta`). The catalog list and Home board are display-sorted by the user's applied
/// add-on order, but the engine's `meta_items` are NOT (a reorder never rewrites the engine's
/// `profile.addons` Vec). Without honoring the same order, a user whose #1 add-on is a localized meta
/// provider (e.g. a French Cinemeta) sees French on the catalog but the DETAIL synopsis resolves from
/// whichever add-on the engine lists first (the protected English Cinemeta, seeded at index 0), i.e.
/// English text under a French title (#144). [pickByAddonOrder] chooses the ready meta whose add-on is
/// earliest in the applied order so the detail honors the same priority the catalog does. With NO
/// applied order (Android today, until the sync/profile layer lands) this is exactly the old `.first`
/// engine-order behavior, so English users and un-reordered accounts are unchanged.
object AddonOrder {
    /// Byte-for-byte with Apple `AddonTombstones.normalize`: trim + lowercase the transport URL so an
    /// applied-order entry matches an engine descriptor base regardless of surrounding whitespace/case.
    fun normalize(url: String): String = url.trim().lowercase()

    /// Pick the entry whose [Ready.base] add-on is earliest in [appliedAddonOrder]. [ready] is every
    /// add-on that returned a ready value, in engine order. With an empty order this returns the first
    /// ready (engine order), identical to the pre-#144 `.first` behavior. Add-ons not in the order sort
    /// AFTER the ordered ones and keep engine order among themselves (a stable min: equal ranks fall
    /// back to the first ready seen). Mirrors Apple `CoreMetaDetails.meta` exactly.
    fun <T> pickByAddonOrder(ready: List<Ready<T>>, appliedAddonOrder: List<String>): T? {
        val first = ready.firstOrNull() ?: return null
        if (appliedAddonOrder.isEmpty()) return first.value
        // Matches Apple `for (i, url) in order.enumerated() { rank[url] = i }`: a duplicate URL keeps its
        // LAST index. A valid applied order has no duplicates, so this is only a faithfulness guard.
        val rank = HashMap<String, Int>(appliedAddonOrder.size)
        appliedAddonOrder.forEachIndexed { i, url -> rank[normalize(url)] = i }
        // Stable min over engine order: a lower rank wins; a ranked add-on beats an unranked one; ties
        // and two-unranked keep the earliest-seen (engine order), matching Apple's `min(by:)` result.
        var best = first
        var bestRank = rank[normalize(first.base)]
        for (candidate in ready.drop(1)) {
            val candidateRank = rank[normalize(candidate.base)]
            if (isBetterRank(candidateRank, bestRank)) {
                best = candidate
                bestRank = candidateRank
            }
        }
        return best.value
    }

    private fun isBetterRank(candidate: Int?, current: Int?): Boolean = when {
        candidate != null && current != null -> candidate < current
        candidate != null && current == null -> true
        else -> false
    }

    /// One add-on's ready value tagged with its transport [base], the pair `pickByAddonOrder` ranks over.
    data class Ready<T>(val base: String, val value: T)
}

/// Whether a Continue-Watching entry is effectively FINISHED and should drop out of the rail
/// (mirrors Apple `CoreCWItem.isFinished`). The engine's `is_in_continue_watching()` is just
/// `time_offset > 0` with no completion check, so a title watched to the end (or marked watched, or
/// finished on another device and synced down) keeps a non-zero offset and lingers forever. This is
/// the data-layer backstop applied before publishing the rail.
///
/// - Series: the only safe finished signal is the CURRENT episode being at/past 0.9 (the finale, or
///   the last episode watched to the credits). A finished episode with a next one rolls `time_offset`
///   back to a low value, so its progress is low and it correctly stays. `timesWatched` counts WATCHED
///   EPISODES, so a mid-series item has it high while still resumable and must NOT gate the rail.
/// - Movie: finished when at/past the 0.9 credits threshold, OR flagged watched
///   ([flaggedWatched] > 0 / [timesWatched] > 0) AND not currently being re-watched. A live, resumable
///   position (progress above 0 but below 0.9) means an active watch/rewatch: keep it even when the
///   watched counters are set.
fun cwItemIsFinished(type: String, progress: Float, flaggedWatched: Int, timesWatched: Int): Boolean {
    val watchedToEnd = progress >= 0.9f
    if (type == "series") return watchedToEnd
    val inProgress = progress > 0f && progress < 0.9f
    if (inProgress) return false
    return watchedToEnd || flaggedWatched > 0 || timesWatched > 0
}

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

/// A single catalog entry (movie, series, etc.), mirroring the engine's `CoreMeta` preview. [poster]
/// is a URL once the engine is wired; until then it is null and the UI renders a deterministic
/// brand-tinted placeholder card. [progress] (0f..1f, null = not in progress) comes from the library's
/// timeOffset/duration on Continue Watching items and drives PosterCard's accent progress track.
///
/// Parity additions (mirroring Apple `CoreMeta`, which reads these from the engine's catalog-preview
/// serialization): [posterShape] (poster/landscape/square, for the card aspect ratio); [logo] (the
/// channel mark on live tv/channel/events previews -- the live surface prefers it over [poster]);
/// [background] (the focused-hero backdrop the browse pages lead with); and [imdbRating]/[genres],
/// which the engine emits inside `links` (category "imdb" carries the rating in its name, category
/// "Genres" carries each genre) rather than as top-level fields -- read the same way Apple's
/// `CoreMeta.imdbRating`/`.genres` do, so the featured hero shows a rating. [resumeSeconds] is the
/// saved resume position in whole seconds on a Continue Watching item (from `state.timeOffset`),
/// surfaced through [resumeLabel] as "Resume 1:03".
data class MetaItem(
    val id: String,
    val type: MediaType,
    val name: String,
    val poster: String? = null,
    val year: String? = null,
    val description: String? = null,
    val progress: Float? = null,
    val posterShape: String? = null,
    val logo: String? = null,
    val background: String? = null,
    val imdbRating: String? = null,
    val genres: List<String> = emptyList(),
    val resumeSeconds: Double? = null,
) {
    /// The formatted "resume 1:03" affordance for a Continue Watching card, or null when there is
    /// nothing to resume (mirrors Apple `CoreCWItem.resumeSeconds` -> `resumeTimecode`).
    val resumeLabel: String? get() = resumeSeconds?.let { resumeTimecode(it) }
}

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
) {
    /// The [released] string parsed as an instant (non-breaking -- display still uses the raw string).
    /// Live/EPG schedules carry an ISO-8601 timestamp here; `OffsetDateTime.parse` handles both the
    /// plain (`2020-01-01T00:00:00Z`) and fractional-seconds (`...000Z`) forms Apple's two
    /// ISO8601DateFormatters cover. Returns null when absent or unparseable. Mirrors Apple
    /// `CoreVideo.releasedDate`; this is the EPG-date foundation the now/next picker (a later round)
    /// builds on.
    val releasedDate: Instant?
        get() {
            val raw = released?.trim().takeUnless { it.isNullOrEmpty() } ?: return null
            return runCatching { OffsetDateTime.parse(raw).toInstant() }
                .recoverCatching { Instant.parse(raw) }
                .getOrNull()
        }
}

/// Episodes ordered by (season, episode, id) across ALL seasons -- the cross-season player list, so
/// in-player Next / auto-advance rolls from a season's last episode into the next season's first
/// (was per-season, so it dead-ended at the last episode of a season). Specials (season 0) sort first
/// and don't interrupt end-of-season advance. Mirrors Apple `[CoreVideo].orderedBySeasonEpisode`.
val List<Episode>.orderedBySeasonEpisode: List<Episode>
    get() = sortedWith(
        compareBy<Episode> { it.season }
            .thenBy { it.episode }
            .thenBy { it.id },
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
    /// The first playable YouTube trailer id, derived at parse time from the meta's `trailerStreams`
    /// (each is a full Stream that flattens to a top-level `ytId`) with a fallback to a `links` entry
    /// categorized "Trailer" pointing at a youtube.com URL. Null when the meta carries no trailer.
    /// Mirrors Apple `CoreMetaItem.trailerYouTubeID`.
    val trailerYouTubeId: String? = null,
) {
    /// All episodes ordered (season, then episode, then id) across EVERY season -- the list handed to
    /// the player so auto-advance rolls past the season boundary. Mirrors Apple
    /// `CoreMetaItem.orderedEpisodes`.
    val orderedEpisodes: List<Episode> get() = videos.orderedBySeasonEpisode

    /// A PROVISIONAL playback duration in seconds parsed from the human [runtime] string ("60 min",
    /// "1h 32m", "92 min", "2:05:00"). Used by community trickplay to key + start capture before the
    /// player emits its real duration. Mirrors Apple `CoreMetaItem.runtimeSeconds` (same clamps: a
    /// garbage value yields null, each field caps at 24h, the total is finite/positive and clamped to a
    /// 24h ceiling). Returns null when no number can be read.
    val runtimeSeconds: Double? get() = parseRuntimeSeconds(runtime)

    companion object {
        private const val MAX_SECONDS = 86_400.0

        /// A minimal placeholder meta for a title whose Cinemeta meta is nil (a brand-new/unreleased
        /// title: the `tt` exists at TMDB but is not yet in Cinemeta). The detail page is driven
        /// entirely by this meta, so a nil meta used to leave an empty hero AND block the sources list.
        /// This synthesizes just enough (id, type, name, and Stremio's standard metahub-by-tt
        /// backdrop/logo) so the hero paints and the stream request can still fire on the `tt`. Mirrors
        /// Apple `CoreMetaItem.placeholder`.
        fun placeholder(id: String, type: MediaType, name: String): MetaDetail {
            val isTt = id.startsWith("tt")
            return MetaDetail(
                id = id,
                type = type,
                name = name,
                background = if (isTt) "https://images.metahub.space/background/big/$id/img" else null,
                logo = if (isTt) "https://images.metahub.space/logo/medium/$id/img" else null,
            )
        }

        /// Extract a YouTube video id from a watch / share / embed URL (or a bare 11-char id). Mirrors
        /// Apple `CoreMetaItem.youTubeID(from:)`.
        fun youTubeId(from: String): String? {
            val trimmed = from.trim()
            runCatching { java.net.URI(trimmed) }.getOrNull()?.let { uri ->
                val host = uri.host?.lowercase()
                if (host != null) {
                    if (host.contains("youtu.be")) {
                        val id = uri.path.trimStart('/').substringAfterLast('/')
                        return id.ifBlank { null }
                    }
                    if (host.contains("youtube.com")) {
                        val query = uri.query.orEmpty()
                        val v = query.split('&')
                            .firstOrNull { it.startsWith("v=") }
                            ?.removePrefix("v=")
                        if (!v.isNullOrEmpty()) return v
                        // /embed/<id>, /shorts/<id>, /v/<id>
                        val last = uri.path.trimStart('/').substringAfterLast('/')
                        return last.ifBlank { null }
                    }
                }
            }
            // Bare 11-character YouTube id.
            val idChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
            if (trimmed.length == 11 && trimmed.all { it in idChars }) return trimmed
            return null
        }

        /// Port of Apple `CoreMetaItem.runtimeSeconds`: parse "h:mm:ss"/"mm:ss" colon form first, then
        /// the "1h 32m" / "92 min" word form. All arithmetic is in Double and every field is capped so a
        /// garbage value ("3000000000000000:00:00") yields null instead of overflowing or poisoning the
        /// duration bucket.
        internal fun parseRuntimeSeconds(runtime: String?): Double? {
            val r = runtime?.lowercase() ?: return null
            fun field(raw: String): Double? {
                val n = raw.trim().toDoubleOrNull() ?: return null
                return if (n.isFinite() && n in 0.0..MAX_SECONDS) n else null
            }
            fun finalize(seconds: Double): Double? {
                if (!seconds.isFinite() || seconds <= 0.0) return null
                return minOf(seconds, MAX_SECONDS)
            }
            if (r.contains(':')) {
                val parts = r.split(':').mapNotNull { field(it) }
                if (parts.size == 3) return finalize(parts[0] * 3600 + parts[1] * 60 + parts[2])
                if (parts.size == 2) return finalize(parts[0] * 60 + parts[1])
            }
            // "1h 32m" / "1 h 32 min" form: sum hours + minutes when an explicit hour marker is present.
            var totalMinutes = 0.0
            var matched = false
            val tokens = Regex("(\\d+)\\s*([a-z]*)").findAll(r)
            for (token in tokens) {
                val n = token.groupValues[1].toDoubleOrNull() ?: break
                if (n < 0 || n > MAX_SECONDS) return null
                val unit = token.groupValues[2]
                if (unit.startsWith("h")) {
                    totalMinutes += n * 60
                } else {
                    totalMinutes += n // bare number or "min" -> minutes
                }
                matched = true
            }
            if (!matched) return null
            return finalize(totalMinutes * 60)
        }
    }
}

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
    /// Engine watched-bookkeeping: `flaggedWatched` (movies) flips to 1 when a movie is marked/played
    /// to the end. Defaults to 0 for older/sparser entries that omit it. Mirrors Apple
    /// `CoreLibState.flaggedWatched`; feeds the Continue-Watching finished-prune ([cwItemIsFinished]).
    val flaggedWatched: Int = 0,
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

    /// The saved resume position in whole seconds (`timeOffset` is ms), so the detail primary button
    /// can read "Resume 1:03". 0 when nothing has been played. Mirrors Apple `CoreCWItem.resumeSeconds`.
    val resumeSeconds: Double get() = maxOf(0.0, timeOffsetMs / 1000.0)

    /// The formatted resume affordance for the detail primary button, or null when nothing to resume
    /// (mirrors Apple `CoreCWItem.resumeSeconds` -> `resumeTimecode`).
    val resumeLabel: String? get() = resumeTimecode(resumeSeconds)
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
    /// True for a DIRECT-PLAY copy resolved from the user's own media server (Plex / Jellyfin / Emby). The
    /// ranker gives these their own top tier (direct-play from your own box is instant + the original file),
    /// the Android analogue of the Apple `CoreStream.vortxProvider` provenance marker. The [id] handle is the
    /// self-authenticating direct stream URL, so the engine's resolve() plays it straight through. Default
    /// false keeps every add-on-sourced stream unchanged.
    val isMediaServer: Boolean = false,
    /// The engine's `StreamSource` (`#[serde(untagged)]` + flattened) fields, decoded optionally so a
    /// stream missing any of them (every torrent/direct/YouTube source) still parses. Mirror of Apple
    /// `CoreStream`: [url] direct/debrid link, [ytId] YouTube source, [infoHash]/[fileIdx] torrent,
    /// [externalUrl] hand-off link, [nzbUrl]/[fileMustInclude] the native USENET source fields (an `.nzb`
    /// link resolved through a usenet-capable debrid account (TorBox), plus an optional regex picking the
    /// video inside a multi-file download).
    val url: String? = null,
    val ytId: String? = null,
    val infoHash: String? = null,
    val fileIdx: Int? = null,
    val externalUrl: String? = null,
    val nzbUrl: String? = null,
    val fileMustInclude: String? = null,
    /// VortX provenance marker: the server UUID on a synthetic MEDIA-SERVER stream, null on every
    /// engine-decoded stream. The STRUCTURAL, text-independent classification hook mirroring Apple
    /// `CoreStream.vortxProvider`. [isMediaServer] remains the ranker's tiering flag; this carries the
    /// provenance id alongside it for the media-server play path.
    val vortxProvider: String? = null,
    /// Per-stream `behaviorHints` (`CoreStreamBehaviorHints`): [bingeGroup] is the auto-advance key (two
    /// streams sharing it are the same source across episodes, so Next keeps the same quality/add-on);
    /// [filename] is the real file name; [notWebReady] flags a stream a plain HTML5 player can't handle.
    val bingeGroup: String? = null,
    val filename: String? = null,
    val notWebReady: Boolean? = null,
) {
    /// A USENET stream: no direct [url] yet, but an `.nzb` link to resolve through a usenet-capable
    /// debrid account. Like a raw torrent, it needs resolution before it is playable. Kept mutually
    /// exclusive from [isTorrent] (which also requires `nzbUrl == null`) so a stream is classified as
    /// exactly one of torrent / usenet / direct. Mirrors Apple `CoreStream.isUsenet`.
    val isUsenet: Boolean get() = url == null && !nzbUrl.isNullOrEmpty()

    /// A bare YouTube source ([ytId], no [url]/[infoHash]): a trailer/clip from a trailer add-on, not a
    /// full feature stream. Playable via the `/yt` route but excluded from quality ranking + auto-pick.
    /// Mirrors Apple `CoreStream.isYouTubeTrailer`.
    val isYouTubeTrailer: Boolean get() = url == null && infoHash == null && !ytId.isNullOrEmpty()

    /// The bare YouTube id of an [isYouTubeTrailer] source-list stream, or null for any other stream, so
    /// the trailer-tap paths can resolve it the same way as the built-in Trailer chip. Mirrors Apple
    /// `CoreStream.youTubeTrailerID`.
    val youTubeTrailerId: String? get() = if (isYouTubeTrailer) ytId else null

    /// The unified playable URL for the non-torrent source kinds, mirroring Apple `CoreStream.playableURL`:
    /// a direct/debrid [url] plays as-is; a [isUsenet] stream is tappable only when a TorBox key can
    /// resolve it ([torBoxConfigured]); a [ytId] source plays through the trailer resolver's `/yt/{id}`
    /// route. Returns null for a raw torrent (Android resolves torrents through the debrid path in
    /// [com.vortx.android.data.CatalogRepository.resolve] rather than a local streaming-server loopback,
    /// which is not wired on Android) and when [torrentsDisabled] gates it out. This is the pure
    /// URL-construction half; the live resolve path applies its own debrid/torrent resolution.
    fun playableUrl(torBoxConfigured: Boolean, torrentsDisabled: Boolean = false): String? {
        url?.let { return it }
        if (isUsenet && torBoxConfigured) nzbUrl?.let { return it }
        if (!ytId.isNullOrEmpty()) return "$TRAILER_RESOLVER_BASE/yt/$ytId"
        if (torrentsDisabled) return null
        // Raw torrent: no local streaming-server loopback on Android (see the resolve path).
        return null
    }

    companion object {
        /// The remote trailer resolver (mirrors Apple `StremioServer.trailerResolverBase`): a gated
        /// VortX edge host that returns a googlevideo URL for a YouTube id, working on every scheme.
        const val TRAILER_RESOLVER_BASE: String = "https://trailer.vortx.tv"
    }
}

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
    /// The provider-agnostic content identity for external progress sync (Trakt / SIMKL scrobble). Null
    /// for a source with no resolvable id (a pasted magnet, a kitsu-only catalog) or for the offline
    /// preview, in which case the player simply does not scrobble. Attached by
    /// [com.vortx.android.ui.viewmodel.DetailViewModel] at play time (the one place that knows the
    /// meta id + chosen episode); [com.vortx.android.integrations.ScrobbleService] consumes it on the
    /// play/pause/stop transitions. Mirrors the Apple `ExternalMediaRef`.
    val mediaRef: MediaRef? = null,
)

/// Provider-agnostic description of the title being scrobbled, resolved ONCE at play time and handed to
/// every connected external-sync provider (Trakt, SIMKL), each of which maps it to its own id bag.
/// Mirrors the Apple `ExternalMediaRef` (app/SourcesShared/ExternalScrobbleProvider.swift): the
/// preferred identity is the IMDb `tt…` id (of the movie, or of the SHOW for a series episode), with a
/// numeric TMDB id as the fallback for a tmdb-only catalog play.
data class MediaRef(
    /// True for a series episode (movie-vs-episode payload shape), false for a movie.
    val isSeries: Boolean,
    /// The resolved IMDb `tt…` id (movie, or show for a series episode). Preferred identity.
    val imdb: String? = null,
    /// Numeric TMDB id fallback, used when no `tt` id could be resolved.
    val tmdb: Int? = null,
    /// 1-based season number for a series episode (null for movies).
    val season: Int? = null,
    /// 1-based episode number for a series episode (null for movies).
    val episode: Int? = null,
    /// Human title, sent as a soft hint only (providers match on ids).
    val title: String? = null,
    /// Release year hint (optional).
    val year: Int? = null,
) {
    /// True when this ref carries at least one usable id; a ref with neither is dropped by the service.
    val hasUsableId: Boolean get() = !imdb.isNullOrEmpty() || tmdb != null
}
