package com.stremiox.android.data

import com.stremiox.android.model.Catalog
import com.stremiox.android.model.Episode
import com.stremiox.android.model.MediaType
import com.stremiox.android.model.MetaDetail
import com.stremiox.android.model.MetaItem
import com.stremiox.android.model.Playable
import com.stremiox.android.model.StreamGroup
import com.stremiox.android.model.StreamSource
import kotlinx.coroutines.delay

/// The seam between the UI and the engine. The Compose screens depend only on this interface, so the
/// real stremio-core-kotlin engine (Rust core over JNI, the same engine the iOS/tvOS apps use) lands
/// behind it in a later iteration with no UI churn. Functions are suspend/Result-shaped to match the
/// async, fallible nature of add-on requests — every call maps to an engine resource load:
///   - [home]/[discover]    -> `catalog_with_filters` / the board rows
///   - [meta]               -> `meta_details.meta`
///   - [streams]            -> `meta_details` stream groups (one per stream add-on)
interface CatalogRepository {
    /// Home rows: Continue Watching first, then the user's add-on catalogs as poster rails.
    suspend fun home(): Result<List<Catalog>>

    /// Discover rows filtered by type (Movie/Series/...), drawn from the installed add-ons.
    suspend fun discover(type: MediaType): Result<List<Catalog>>

    /// The user's saved Library (bookmarked titles).
    suspend fun library(): Result<List<MetaItem>>

    /// Full-text search across every add-on the user has installed.
    suspend fun search(query: String): Result<List<MetaItem>>

    /// Full meta detail for a title (hero artwork, metadata, episodes), resolved through the user's
    /// meta add-ons so every id scheme (tt, tmdb:, tvdb:, …) works.
    suspend fun meta(type: MediaType, id: String): Result<MetaDetail>

    /// Every playable source for a title, grouped by the add-on that returned it, best first. This is
    /// where the real engine fans out to every installed stream add-on; the preview returns a stub.
    suspend fun streams(type: MediaType, id: String): Result<List<StreamGroup>>

    /// Resolve a chosen [StreamSource] into a directly-playable [Playable] for the player. The engine
    /// does whatever the source requires: hand a magnet to the in-process streaming server and return
    /// its local HLS URL, unlock a debrid link, or pass an HTTP link straight through. It also folds in
    /// the per-profile resume position. The player only ever receives a concrete URL.
    suspend fun resolve(source: StreamSource): Result<Playable>
}

/// The canonical name for the engine seam. The screens were built against [CatalogRepository]; the
/// real stremio-core JNI binding implements this same contract under the `StremioRepository` name.
/// One interface, two names, zero UI churn when the engine lands.
typealias StremioRepository = CatalogRepository

/// Offline preview data so the UI builds, runs, and is CI-verifiable before the engine is wired.
/// Every poster/backdrop is null on purpose: the UI must look intentional without images, since real
/// artwork URLs only arrive once the engine is connected. This is replaced, not extended, by the
/// engine impl. A small artificial [latencyMs] lets the loading states actually render in a debug
/// build, the way an add-on round-trip would.
class PreviewCatalogRepository(
    private val latencyMs: Long = 300L,
) : CatalogRepository {

    private fun sample(prefix: String, type: MediaType, count: Int): List<MetaItem> =
        (1..count).map { i ->
            MetaItem(
                id = "$prefix-$i",
                type = type,
                name = "$prefix Title $i",
                year = "20${10 + (i % 15)}",
            )
        }

    override suspend fun home(): Result<List<Catalog>> {
        delay(latencyMs)
        return Result.success(
            listOf(
                Catalog("continue", "Continue Watching", sample("Resume", MediaType.SERIES, 6)),
                Catalog("popular-movies", "Popular Movies", sample("Movie", MediaType.MOVIE, 10)),
                Catalog("popular-series", "Popular Series", sample("Series", MediaType.SERIES, 10)),
                Catalog("trending", "Trending Now", sample("Trending", MediaType.MOVIE, 10)),
            )
        )
    }

    override suspend fun discover(type: MediaType): Result<List<Catalog>> {
        delay(latencyMs)
        return Result.success(
            listOf(
                Catalog("top", "Top ${type.label}", sample(type.label, type, 10)),
                Catalog("new", "New ${type.label}", sample("New ${type.label}", type, 10)),
            )
        )
    }

    override suspend fun library(): Result<List<MetaItem>> {
        delay(latencyMs)
        return Result.success(sample("Saved", MediaType.MOVIE, 8))
    }

    override suspend fun search(query: String): Result<List<MetaItem>> {
        if (query.isBlank()) return Result.success(emptyList())
        delay(latencyMs)
        return Result.success(sample(query, MediaType.MOVIE, 12))
    }

    override suspend fun meta(type: MediaType, id: String): Result<MetaDetail> {
        delay(latencyMs)
        val name = id.substringBeforeLast('-').ifBlank { "Title" } + " " + id.substringAfterLast('-')
        val videos = if (type == MediaType.SERIES) {
            (1..2).flatMap { season ->
                (1..6).map { ep ->
                    Episode(
                        id = "$id:$season:$ep",
                        title = "Episode $ep",
                        season = season,
                        episode = ep,
                        overview = "Preview episode synopsis. Real overviews arrive with the engine.",
                    )
                }
            }
        } else {
            emptyList()
        }
        return Result.success(
            MetaDetail(
                id = id,
                type = type,
                name = name.trim(),
                description = "A placeholder synopsis. Real metadata, artwork, and ratings load " +
                    "from your installed add-ons once the stremio-core engine is wired over JNI.",
                releaseInfo = "2021",
                runtime = if (type == MediaType.SERIES) "45 min" else "2h 08m",
                imdbRating = "7.8",
                genres = listOf("Drama", "Thriller", "Mystery"),
                videos = videos,
            )
        )
    }

    override suspend fun streams(type: MediaType, id: String): Result<List<StreamGroup>> {
        delay(latencyMs)
        // A representative stub of the per-add-on, multi-quality source list the engine returns. The
        // real impl fans out to every installed stream add-on; the UI hierarchy is identical.
        return Result.success(
            listOf(
                StreamGroup(
                    addon = "Torrentio",
                    streams = listOf(
                        StreamSource("$id-t1", "Torrentio", "$id 2160p · HDR10 · REMUX", "BluRay · 18.4 GB · 84 peers", "4K", isTorrent = true),
                        StreamSource("$id-t2", "Torrentio", "$id 1080p · WEB-DL", "WEB-DL · 4.1 GB · 220 peers", "1080p", isTorrent = true),
                        StreamSource("$id-t3", "Torrentio", "$id 720p · WEBRip", "WEBRip · 1.4 GB · 60 peers", "720p", isTorrent = true),
                    ),
                ),
                StreamGroup(
                    addon = "Comet",
                    streams = listOf(
                        StreamSource("$id-c1", "Comet", "$id 1080p · Dolby Vision", "Debrid cached · instant", "1080p"),
                        StreamSource("$id-c2", "Comet", "$id 4K · Atmos", "Debrid cached · instant", "4K"),
                    ),
                ),
            )
        )
    }

    override suspend fun resolve(source: StreamSource): Result<Playable> {
        delay(latencyMs)
        // The preview hands back a real, public, royalty-free test stream so the player can be
        // exercised end to end before the engine + streaming server exist. Torrent sources resolve to
        // an adaptive HLS asset (the shape a streaming-server resolve produces); direct sources resolve
        // to a progressive MP4. Both are Google's long-lived ExoPlayer sample assets.
        val playable = if (source.isTorrent) {
            Playable(
                url = SAMPLE_HLS_URL,
                title = source.title,
                viaStreamingServer = true,
            )
        } else {
            Playable(
                url = SAMPLE_MP4_URL,
                title = source.title,
                viaStreamingServer = false,
            )
        }
        return Result.success(playable)
    }

    private companion object {
        // Public ExoPlayer sample assets (Apache-2.0 test media), used only by the offline preview.
        const val SAMPLE_HLS_URL =
            "https://storage.googleapis.com/exoplayer-test-media-1/gen-3/screens/dash-vod-single-segment/master.m3u8"
        const val SAMPLE_MP4_URL =
            "https://storage.googleapis.com/exoplayer-test-media-0/play.mp4"
    }
}

/// The mock seam the UI runs on until the engine is wired. Same contract, mock data; the JNI engine
/// impl replaces it wholesale. Named to match [StremioRepository] for clarity at the injection site.
typealias MockStremioRepository = PreviewCatalogRepository
