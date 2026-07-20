package com.vortx.android.data

import com.vortx.android.model.Catalog
import com.vortx.android.model.DiscoverFilters
import com.vortx.android.model.DiscoverResult
import com.vortx.android.model.DiscoverTypeOption
import com.vortx.android.model.Episode
import com.vortx.android.model.InstalledAddon
import com.vortx.android.model.LibraryFilters
import com.vortx.android.model.LibraryPortability
import com.vortx.android.model.LibraryResult
import com.vortx.android.model.LibrarySortOption
import com.vortx.android.model.LibraryTypeOption
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaDetail
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow

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

    /// CONTINUOUS Home rows: emits the current rail set immediately and again every time the engine's
    /// underlying state changes (each add-on catalog answering, Continue Watching updating, a
    /// sign-in/sign-out swapping the whole catalog set). The engine is event-driven -- a board load is
    /// not one response but a stream of partial settlements, one per add-on -- so Home must collect
    /// this for the screen's lifetime and render incrementally; a one-shot [home] call can only ever
    /// see whichever instant it sampled (the S03 device round proved that renders empty rails).
    /// Emissions are conflated + deduplicated; the flow never completes (cancel via scope).
    ///
    /// Default = a single [home] emission, so the offline preview impl (and any other one-shot
    /// implementation) satisfies the contract without change.
    fun homeUpdates(): Flow<List<Catalog>> = flow { emit(home().getOrThrow()) }

    /// CONTINUOUS ctx/library change ticks -- the Group-1 reactivity primitive every other mutable
    /// surface (Library, Detail's Saved chip, Discover's current selection, the installed-addons list)
    /// is built on, mirroring [homeUpdates]'s pattern for the same class of bug: Add-to-Library,
    /// Remove-from-Library, InstallAddon, UninstallAddon, sign-in, and sign-out are all whole-model ctx
    /// broadcasts (`field = null`) in the engine, so a screen that only reads state ONCE at load time
    /// (a one-shot suspend call) can never see a change made by a DIFFERENT screen/action -- it renders
    /// whatever it happened to snapshot at construction time until it is torn down and recreated (an
    /// app restart) or some UNRELATED interaction (a filter chip tap) happens to force a fresh read.
    /// That is the exact shape of the device-round bugs: Library not updating after Add-to-Library from
    /// Detail, Detail's Saved chip not updating after a remove from the Library grid, Discover's
    /// catalogs not updating after an add-on install/remove or a sign-in. Emits once immediately (so a
    /// fresh collector always gets an initial tick) and again on every relevant engine change; never
    /// completes (cancel via the collecting scope).
    ///
    /// Default = a single emission, so the offline preview impl (and any future one-shot
    /// implementation) satisfies the contract without change -- its mutations are already synchronous
    /// local list edits the caller re-reads directly, so there is nothing to observe.
    fun ctxUpdates(): Flow<Unit> = flow { emit(Unit) }

    /// Discover: the currently selected catalog's items plus the type/catalog/genre pivot chips
    /// (S04). [requestJson] is null for the engine's own default selection (first load), or the exact
    /// `request` JSON echoed back from a [DiscoverFilters] type/catalog/genre option the caller tapped
    /// -- the request must be re-dispatched byte-for-byte, never reconstructed client-side (that
    /// reconstruction gap was the "type chips are inert" bug this session fixes).
    suspend fun discover(requestJson: String? = null): Result<DiscoverResult>

    /// Load the next page of the CURRENTLY selected Discover catalog (infinite scroll / "Load more").
    suspend fun discoverNextPage(): Result<DiscoverResult>

    /// The user's saved Library (bookmarked titles) plus the type/sort pivot chips (S04). [requestJson]
    /// is null for the default (all types, last-watched), or a verbatim echo of a [LibraryFilters]
    /// type/sort option's `request`.
    suspend fun library(requestJson: String? = null): Result<LibraryResult>

    /// The saved Library as PORTABLE export items: the same entries [library] returns, but carrying each
    /// one's resume state and with the engine's `removed`/`temp` bookkeeping entries filtered out. Feeds
    /// [com.vortx.android.library.LibraryTransfer]'s export; separate from [library] because the UI
    /// projection ([MetaItem]) deliberately drops those fields.
    ///
    /// [now] is the ISO timestamp stamped on every exported item (the engine's entries carry a resume
    /// state but no per-item last-watched clock). Default: an empty list, so a non-engine repository (the
    /// Compose previews) reports "nothing to export" rather than pretending.
    suspend fun libraryPortableItems(now: String): Result<List<LibraryPortability.Item>> =
        Result.success(emptyList())

    /// Add a title to the Library (the "Save"/bookmark action from a poster's long-press menu or the
    /// detail page).
    suspend fun addToLibrary(item: MetaItem): Result<Unit>

    /// Remove a title from the Library (the Library grid's per-poster "x" control, DESIGN-SYSTEM.md §4
    /// "Library").
    suspend fun removeFromLibrary(id: String): Result<Unit>

    /// Every add-on installed on the signed-in account (S04 "Add-on management"), read live from
    /// `ctx.profile.addons`.
    suspend fun installedAddons(): Result<List<InstalledAddon>>

    /// Install (or update-in-place) an add-on from a pasted manifest URL. Fetches + validates the
    /// manifest first (mirrors Apple `CoreBridge.installAddon`); the [Result.failure] message is
    /// user-facing.
    suspend fun installAddon(url: String): Result<Unit>

    /// Remove an installed add-on (the Add-ons screen's per-row "Remove" control). Protected/official
    /// add-ons are still removable at the repository level; the UI is responsible for hiding the
    /// control for [InstalledAddon.isProtected] entries, mirroring Apple `AddonsView`'s
    /// `!addon.isProtected` gate.
    suspend fun removeAddon(addon: InstalledAddon): Result<Unit>

    /// Turn an installed add-on on/off for the ACTIVE profile (the Add-ons screen's eye toggle,
    /// Apple `AddonsView.swift:424` -> `Profiles.swift:348 toggleAddon`). A per-profile RENDER-LAYER
    /// overlay, never an engine/account change: a disabled add-on stays installed but is excluded
    /// from this profile's Home board rows and stream-source groups. Default no-op so the offline
    /// preview (which models no profiles) satisfies the contract unchanged.
    suspend fun setAddonDisabled(transportUrl: String, disabled: Boolean): Result<Unit> = Result.success(Unit)

    /// Persist the user's add-on PRIORITY order (the Add-ons screen's drag-reorder, Apple
    /// `AddonsView.swift:476 .onMove` -> `VortXSyncManager.applyInAppAddonOrder`). Display/pick-order
    /// only -- the engine's `profile.addons` Vec is never rewritten, same as Apple. Default no-op for
    /// the offline preview.
    suspend fun applyAddonOrder(transportUrls: List<String>): Result<Unit> = Result.success(Unit)

    /// Mark a CATALOG item watched/unwatched from its poster card, WITHOUT opening the detail page
    /// first (Apple `iOSRootView.swift:4260` -> `CoreBridge.setCatalogWatched`). The detail screen's
    /// [setWatched] cannot serve a card: its engine action (`MetaDetails -> MarkAsWatched`) acts on
    /// the currently OPEN `meta_details`, which a card tap never loaded. The engine's
    /// `MetaItemMarkAsWatched` creates a temporary library item when none exists, which is exactly
    /// the card/discover use case. Default no-op for the offline preview.
    suspend fun setCatalogWatched(item: MetaItem, isWatched: Boolean): Result<Unit> = Result.success(Unit)

    /// Full-text search across every add-on the user has installed.
    suspend fun search(query: String): Result<List<MetaItem>>

    /// Full meta detail for a title (hero artwork, metadata, episodes), resolved through the user's
    /// meta add-ons so every id scheme (tt, tmdb:, tvdb:, …) works.
    suspend fun meta(type: MediaType, id: String): Result<MetaDetail>

    /// Every playable source for a title, grouped by the add-on that returned it, best first. This is
    /// where the real engine fans out to every installed stream add-on; the preview returns a stub.
    ///
    /// For a series, pass the chosen [episodeId] (the engine `CoreVideo.id`, e.g. `tt123:1:2`) so the
    /// engine fetches THAT episode's streams; for a movie (or a series' auto-picked first episode) leave
    /// it null and the engine guesses the best stream for the title. The default keeps every existing
    /// caller (movies, the hero Watch button) source-compatible.
    suspend fun streams(type: MediaType, id: String, episodeId: String? = null): Result<List<StreamGroup>>

    /// Resolve a chosen [StreamSource] into a directly-playable [Playable] for the player. The engine
    /// does whatever the source requires: hand a magnet to the in-process streaming server and return
    /// its local HLS URL, unlock a debrid link, or pass an HTTP link straight through. It also folds in
    /// the per-profile resume position. The player only ever receives a concrete URL.
    suspend fun resolve(source: StreamSource): Result<Playable>

    // ---- Live playback progress (engine Player) ----
    //
    // Mirrors Apple's `CoreBridge` Player lifecycle so Continue Watching + resume track on Android too.
    // Default bodies are benign no-ops, so the offline preview (whose progress is not engine-backed) and
    // any future one-shot implementation satisfy the contract without change; [EngineStremioRepository]
    // overrides them for the real engine dispatch.

    /// Load the engine Player for the title currently open in `meta_details`, so subsequent
    /// [reportProgress] ticks attribute to the right library item. Call once when playback begins.
    suspend fun beginPlaybackSession(): Result<Unit> = Result.success(Unit)

    /// Report the live playback position + duration (ms) to the engine, so Continue Watching updates.
    /// Call periodically while playing.
    suspend fun reportProgress(positionMs: Long, durationMs: Long): Result<Unit> = Result.success(Unit)

    /// Report a final position and tear the engine Player down. Call once when the player closes (save on
    /// exit). A near-the-end position additionally marks the title watched.
    suspend fun endPlaybackSession(positionMs: Long, durationMs: Long): Result<Unit> = Result.success(Unit)

    // ---- S05: Detail watched-state + library mutations ----
    //
    // Every mutation returns the freshly re-pulled [MetaDetail] so the caller can swap its state in one
    // step (ticks/progress/library-chip flip live) instead of a separate reload. Default bodies just
    // re-fetch [meta] unchanged, so an implementation that predates this session (the offline preview,
    // any future repository that doesn't model mutation) still satisfies the contract with a benign
    // no-op rather than a compile break; [EngineStremioRepository] overrides every one of these for the
    // real engine dispatch.

    /// Mark the whole title (movie, or every episode of a series) watched/unwatched.
    suspend fun setWatched(type: MediaType, id: String, isWatched: Boolean): Result<MetaDetail> = meta(type, id)

    /// Mark one series episode watched/unwatched. [videoId] is the engine `CoreVideo.id`.
    suspend fun setVideoWatched(
        type: MediaType,
        id: String,
        videoId: String,
        season: Int?,
        episode: Int?,
        isWatched: Boolean,
    ): Result<MetaDetail> = meta(type, id)

    /// Mark every episode of one season watched/unwatched.
    suspend fun setSeasonWatched(type: MediaType, id: String, season: Int, isWatched: Boolean): Result<MetaDetail> =
        meta(type, id)

    /// Save the open title to the library.
    suspend fun addToLibrary(type: MediaType, id: String, name: String, poster: String?): Result<MetaDetail> =
        meta(type, id)

    /// Remove the open title from the library.
    suspend fun removeFromLibrary(type: MediaType, id: String): Result<MetaDetail> = meta(type, id)

    /// A pure LOCAL re-read of the currently-loaded title's meta (no re-dispatch of a Load action),
    /// for [ctxUpdates] consumers that only want to pick up a library/watched-state change made
    /// elsewhere without re-triggering the add-on network fan-out every tick. Null when nothing is
    /// currently loaded for [id], or the implementation has no such local snapshot (default: falls back
    /// to a full [meta] reload, which is still correct, just not the cheap path).
    suspend fun peekMeta(type: MediaType, id: String): MetaDetail? = meta(type, id).getOrNull()
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

    /// The type currently "selected" in the preview Discover chips (there is no real engine selectable
    /// to echo, so this stands in for it across calls in this offline-only implementation).
    private var previewDiscoverType: MediaType = MediaType.MOVIE

    private fun previewDiscoverFilters(): DiscoverFilters =
        DiscoverFilters(
            types = MediaType.entries.map {
                DiscoverTypeOption(it.label, it == previewDiscoverType, it.id)
            },
        )

    override suspend fun discover(requestJson: String?): Result<DiscoverResult> {
        delay(latencyMs)
        if (requestJson != null) {
            previewDiscoverType = MediaType.entries.find { it.id == requestJson } ?: previewDiscoverType
        }
        val type = previewDiscoverType
        return Result.success(
            DiscoverResult(
                items = sample("Top ${type.label}", type, 16),
                filters = previewDiscoverFilters(),
            ),
        )
    }

    override suspend fun discoverNextPage(): Result<DiscoverResult> = discover(null)

    private val previewLibrary = mutableListOf<MetaItem>().apply { addAll(sample("Saved", MediaType.MOVIE, 8)) }

    override suspend fun library(requestJson: String?): Result<LibraryResult> {
        delay(latencyMs)
        return Result.success(
            LibraryResult(
                items = previewLibrary.toList(),
                filters = LibraryFilters(
                    types = listOf(LibraryTypeOption("All", true, "")),
                    sorts = listOf(LibrarySortOption("Recent", true, "")),
                ),
            ),
        )
    }

    override suspend fun addToLibrary(item: MetaItem): Result<Unit> {
        delay(latencyMs)
        previewLibrary.removeAll { it.id == item.id }
        previewLibrary.add(0, item)
        return Result.success(Unit)
    }

    override suspend fun removeFromLibrary(id: String): Result<Unit> {
        delay(latencyMs)
        previewLibrary.removeAll { it.id == id }
        return Result.success(Unit)
    }

    private val previewAddons = mutableListOf(
        InstalledAddon(
            transportUrl = "https://v3-cinemeta.strem.io/manifest.json",
            name = "Cinemeta",
            isOfficial = true,
            isProtected = true,
            providesStreams = false,
            rawDescriptorJson = "{}",
        ),
    )

    override suspend fun installedAddons(): Result<List<InstalledAddon>> {
        delay(latencyMs)
        return Result.success(previewAddons.toList())
    }

    override suspend fun installAddon(url: String): Result<Unit> {
        delay(latencyMs)
        if (url.isBlank()) return Result.failure(IllegalArgumentException("Enter a valid add-on URL."))
        previewAddons.add(
            InstalledAddon(
                transportUrl = url,
                name = url.substringAfterLast('/').ifBlank { url },
                rawDescriptorJson = "{}",
            ),
        )
        return Result.success(Unit)
    }

    override suspend fun removeAddon(addon: InstalledAddon): Result<Unit> {
        delay(latencyMs)
        previewAddons.removeAll { it.transportUrl == addon.transportUrl }
        return Result.success(Unit)
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

    override suspend fun streams(type: MediaType, id: String, episodeId: String?): Result<List<StreamGroup>> {
        delay(latencyMs)
        // A representative stub of the per-add-on, multi-quality source list the engine returns. The
        // real impl fans out to every installed stream add-on; the UI hierarchy is identical. The
        // preview ignores [episodeId] (its stub sources are title-level), but accepts it to stay
        // signature-compatible with the engine impl.
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
