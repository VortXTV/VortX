package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import com.vortx.android.R
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.model.InstalledAddon
import com.vortx.android.config.RemoteConfig
import com.vortx.android.net.VortXEdgeAuth
import com.vortx.android.profile.ProfileStore
import com.vortx.android.trickplay.TmdbImdbResolution
import com.vortx.android.trickplay.TmdbImdbResolver
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDate
import java.util.Locale

internal const val SHOW_COLLECTIONS_HUB_KEY = "vortx.home.showCollectionsHub"
internal const val COLLECTIONS_REFRESH_CADENCE_KEY = "vortx.collections.refreshCadence"
internal const val COLLECTIONS_SELECTED_PROVIDERS_KEY = "vortx.collections.selectedProviders"
// Discover region override (Apple `vortx.discover.regionPreference`, uppercased): forces the hub's TMDB
// watch_region so an out-of-region user can browse another market. Blank/absent => the device locale region.
internal const val DISCOVER_REGION_PREFERENCE_KEY = "vortx.discover.regionPreference"
internal const val COLLECTIONS_HUB_ENABLED_DEFAULT = true
// RemoteConfig fleet kill-switch (Apple CollectionsHubModel.isAvailable): a remote `false` hides the hub
// fleet-wide (e.g. if the catalogs edge is down). Baked default true => absent/null remote == shipping.
internal const val COLLECTIONS_HUB_FEATURE_KEY = "collectionsHub"
internal const val COLLECTIONS_HUB_FEATURE_DEFAULT = true
internal const val COLLECTIONS_REFRESH_CADENCE_DEFAULT = "daily"
internal const val COLLECTIONS_SELECTED_PROVIDERS_DEFAULT = ""
private const val COLLECTIONS_PROVIDER_CACHE_PREFIX = "vortx.collections.providers."
private const val COLLECTIONS_PROVIDER_CACHE_AT_PREFIX = "vortx.collections.providersAt."
private const val COLLECTIONS_ART_CACHE_PREFIX = "vortx.collections.tileArt."
private const val COLLECTIONS_ART_CACHE_AT_PREFIX = "vortx.collections.tileArtAt."
private const val COLLECTIONS_EDGE_BASE = "https://catalogs.vortx.tv/3"
private const val COLLECTIONS_EDGE_TIMEOUT_MS = 12_000

internal enum class CollectionsHubGroup { DISCOVER, STREAMING, GENRES }

internal sealed interface CollectionsHubLabel {
    data class Resource(@param:StringRes val resourceId: Int) : CollectionsHubLabel
    data class Literal(val value: String) : CollectionsHubLabel
}

internal sealed interface CollectionsHubTarget {
    val id: String
    val title: CollectionsHubLabel

    data class Discover(val list: DiscoverList) : CollectionsHubTarget {
        override val id = "discover:${list.wire}"
        override val title = CollectionsHubLabel.Resource(list.titleResource)
    }

    data class Service(val providerId: Int, val name: String) : CollectionsHubTarget {
        override val id = "service:$providerId"
        override val title = CollectionsHubLabel.Literal(name)
    }

    data class Genre(val spec: GenreSpec) : CollectionsHubTarget {
        override val id = "genre:${spec.id}"
        override val title = CollectionsHubLabel.Resource(spec.titleResource)
    }

    data class Decade(val spec: DecadeSpec) : CollectionsHubTarget {
        override val id = "decade:${spec.id}"
        override val title = CollectionsHubLabel.Literal(spec.title)
    }
}

internal data class CollectionsHubTile(
    val id: String,
    val title: CollectionsHubLabel,
    val subtitle: CollectionsHubLabel? = null,
    val imageUrl: String? = null,
    val target: CollectionsHubTarget,
)

internal data class CollectionsHubSnapshot(
    val enabled: Boolean = false,
    val discover: List<CollectionsHubTile> = emptyList(),
    val streaming: List<CollectionsHubTile> = emptyList(),
    val streamingLoading: Boolean = false,
    val streamingLoadFailed: Boolean = false,
    val genres: List<CollectionsHubTile> = emptyList(),
    val decades: List<CollectionsHubTile> = emptyList(),
) {
    val isVisible: Boolean get() = enabled &&
        (discover.isNotEmpty() || streaming.isNotEmpty() || genres.isNotEmpty() || decades.isNotEmpty())
}

internal data class CollectionsHubBrowseState(
    val target: CollectionsHubTarget? = null,
    val categories: List<CollectionsHubCategory> = emptyList(),
    val selectedCategory: CollectionsHubCategory? = null,
    val items: List<MetaItem> = emptyList(),
    val loading: Boolean = false,
    val error: CollectionsHubError? = null,
    val page: Int = 0,
    val hasMore: Boolean = false,
) {
    val phase: CollectionsHubBrowsePhase
        get() = when {
            target == null -> CollectionsHubBrowsePhase.IDLE
            loading && items.isEmpty() -> CollectionsHubBrowsePhase.LOADING
            error != null && items.isEmpty() -> CollectionsHubBrowsePhase.ERROR
            items.isEmpty() -> CollectionsHubBrowsePhase.EMPTY
            else -> CollectionsHubBrowsePhase.CONTENT
        }
}

internal enum class CollectionsHubBrowsePhase { IDLE, LOADING, ERROR, EMPTY, CONTENT }

internal enum class CollectionsHubError(@param:StringRes val messageResource: Int) {
    LOAD(R.string.collections_browse_load_error),
    LOAD_MORE(R.string.collections_browse_load_more_error),
}

internal data class CollectionsHubCategory(
    val id: String,
    @param:StringRes val titleResource: Int,
)

internal data class CollectionsHubPage(val items: List<MetaItem>, val hasMore: Boolean)

internal enum class DiscoverList(
    val wire: String,
    @param:StringRes val titleResource: Int,
    @param:StringRes val subtitleResource: Int,
) {
    TRENDING("trending", R.string.collections_discover_trending, R.string.collections_discover_trending_subtitle),
    POPULAR("popular", R.string.collections_discover_popular, R.string.collections_discover_popular_subtitle),
    LATEST("latest", R.string.collections_discover_latest, R.string.collections_discover_latest_subtitle),
    UPCOMING("upcoming", R.string.collections_discover_upcoming, R.string.collections_discover_upcoming_subtitle);

    /** The TMDB movie-list path whose first result gives this card its representative backdrop (Apple parity). */
    val backdropListPath: String
        get() = when (this) {
            TRENDING -> "/trending/movie/week"
            POPULAR -> "/movie/popular"
            LATEST -> "/movie/now_playing"
            UPCOMING -> "/movie/upcoming"
        }
}

internal data class GenreSpec(
    val id: String,
    @param:StringRes val titleResource: Int,
    val movieGenreId: Int?,
    val tvGenreId: Int?,
    val keyword: Int? = null,
    val originalLanguage: String? = null,
)

/** A browse-by-decade tile: a release-year window baked into every discover query. Mirrors Apple DecadeSpec. */
internal data class DecadeSpec(
    val id: String,
    val title: String,
    val startYear: Int,
    val endYear: Int,
)

/**
 * Representative artwork for the static hub tiles, keyed by tile id ("discover:trending" / "genre:action" /
 * "decade:2020s"). Resolved off the catalogs edge and cached per region on the hub cadence; a tile with no
 * entry falls back to its gradient (the UI never blanks). Mirrors Apple's genre/discover/decade backdrops.
 */
internal data class CollectionsHubArtwork(val byTileId: Map<String, String> = emptyMap())

internal interface CollectionsHubSource {
    suspend fun providers(region: String, selectedProviderIds: List<Int>): List<CollectionsHubTile>
    suspend fun page(
        target: CollectionsHubTarget,
        category: CollectionsHubCategory,
        region: String,
        page: Int,
        tmdbCatalogSupported: Boolean,
    ): CollectionsHubPage

    /**
     * Resolve a representative backdrop / cover per static tile (Discover cards, genres, decades), keyed by
     * tile id. Batched 429-safely; fail-soft to empty. Defaulted so test doubles and non-edge sources need
     * not implement it (they simply carry the gradient fallback).
     */
    suspend fun artwork(
        region: String,
        genres: List<GenreSpec>,
        decades: List<DecadeSpec>,
    ): CollectionsHubArtwork = CollectionsHubArtwork()
}

internal data class CollectionsHubProviderCache(val encoded: String?, val savedAtMillis: Long)

internal interface CollectionsHubPreferences {
    fun enabled(): Boolean
    fun refreshCadence(): String
    fun selectedProviders(): String
    /** The uppercased 2-letter Discover region override, or null to use the device locale region. */
    fun regionOverride(): String? = null
    fun providerCache(scope: String): CollectionsHubProviderCache
    fun saveProviderCache(scope: String, encoded: String, savedAtMillis: Long)
    // Cadence-cached representative artwork (defaulted so test doubles need not implement it).
    fun artworkCache(scope: String): CollectionsHubProviderCache = CollectionsHubProviderCache(null, 0L)
    fun saveArtworkCache(scope: String, encoded: String, savedAtMillis: Long) {}
    fun observe(listener: (String) -> Unit)
    fun close()
}

private class AndroidCollectionsHubPreferences(context: Context) : CollectionsHubPreferences {
    private val prefs = context.applicationContext
        .getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private var preferenceListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun enabled(): Boolean = prefs.getBoolean(SHOW_COLLECTIONS_HUB_KEY, COLLECTIONS_HUB_ENABLED_DEFAULT)

    override fun refreshCadence(): String =
        prefs.getString(COLLECTIONS_REFRESH_CADENCE_KEY, COLLECTIONS_REFRESH_CADENCE_DEFAULT)
            ?: COLLECTIONS_REFRESH_CADENCE_DEFAULT

    override fun selectedProviders(): String =
        prefs.getString(COLLECTIONS_SELECTED_PROVIDERS_KEY, COLLECTIONS_SELECTED_PROVIDERS_DEFAULT).orEmpty()

    override fun regionOverride(): String? =
        prefs.getString(DISCOVER_REGION_PREFERENCE_KEY, null)
            ?.trim()
            ?.uppercase(Locale.ROOT)
            ?.takeIf { it.length == 2 && it.all(Char::isLetter) }

    override fun providerCache(scope: String): CollectionsHubProviderCache = CollectionsHubProviderCache(
        encoded = prefs.getString("$COLLECTIONS_PROVIDER_CACHE_PREFIX$scope", null),
        savedAtMillis = prefs.getLong("$COLLECTIONS_PROVIDER_CACHE_AT_PREFIX$scope", 0L),
    )

    override fun saveProviderCache(scope: String, encoded: String, savedAtMillis: Long) {
        prefs.edit()
            .putString("$COLLECTIONS_PROVIDER_CACHE_PREFIX$scope", encoded)
            .putLong("$COLLECTIONS_PROVIDER_CACHE_AT_PREFIX$scope", savedAtMillis)
            .apply()
    }

    override fun artworkCache(scope: String): CollectionsHubProviderCache = CollectionsHubProviderCache(
        encoded = prefs.getString("$COLLECTIONS_ART_CACHE_PREFIX$scope", null),
        savedAtMillis = prefs.getLong("$COLLECTIONS_ART_CACHE_AT_PREFIX$scope", 0L),
    )

    override fun saveArtworkCache(scope: String, encoded: String, savedAtMillis: Long) {
        prefs.edit()
            .putString("$COLLECTIONS_ART_CACHE_PREFIX$scope", encoded)
            .putLong("$COLLECTIONS_ART_CACHE_AT_PREFIX$scope", savedAtMillis)
            .apply()
    }

    override fun observe(listener: (String) -> Unit) {
        check(preferenceListener == null)
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key != null) listener(key)
        }.also {
            preferenceListener = it
            prefs.registerOnSharedPreferenceChangeListener(it)
        }
    }

    override fun close() {
        preferenceListener?.let(prefs::unregisterOnSharedPreferenceChangeListener)
        preferenceListener = null
    }
}

private fun defaultCollectionsRegion(): String =
    Locale.getDefault().country.uppercase(Locale.ROOT).ifBlank { "US" }

/** Shared Home collections state backed by Apple's exact toggle and cadence keys. */
internal class CollectionsHubModel internal constructor(
    private val preferences: CollectionsHubPreferences,
    private val source: CollectionsHubSource,
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val deviceRegion: () -> String = ::defaultCollectionsRegion,
    private val tmdbCatalogSupported: suspend () -> Boolean = { false },
    private val beforePaginationPublication: () -> Unit = {},
) {
    constructor(
        context: Context,
        source: CollectionsHubSource = EdgeCollectionsHubSource(context.applicationContext),
        nowMillis: () -> Long = System::currentTimeMillis,
        tmdbCatalogSupported: suspend () -> Boolean = { false },
    ) : this(
        preferences = AndroidCollectionsHubPreferences(context.applicationContext),
        source = source,
        nowMillis = nowMillis,
        tmdbCatalogSupported = tmdbCatalogSupported,
    )

    private val loadMutex = Mutex()
    private val artworkMutex = Mutex()
    private val browseMutex = Mutex()
    private val stateLock = Any()
    private var loadGeneration = 0L
    private var browseGeneration = 0L
    private var closed = false
    private var featureEnabled = enabled()
    /** Representative tile artwork (Discover/genre/decade backdrops), applied in [baseSnapshot]. */
    private var artwork = CollectionsHubArtwork()

    private val _snapshot = MutableStateFlow(initialSnapshot(featureEnabled))
    val snapshot: StateFlow<CollectionsHubSnapshot> = _snapshot.asStateFlow()

    private val _browse = MutableStateFlow(CollectionsHubBrowseState())
    val browse: StateFlow<CollectionsHubBrowseState> = _browse.asStateFlow()

    private val _settingsChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val settingsChanges: SharedFlow<Unit> = _settingsChanges.asSharedFlow()

    private val listener: (String) -> Unit = { key ->
        if (key == SHOW_COLLECTIONS_HUB_KEY ||
            key == COLLECTIONS_REFRESH_CADENCE_KEY ||
            key == COLLECTIONS_SELECTED_PROVIDERS_KEY ||
            key == DISCOVER_REGION_PREFERENCE_KEY
        ) {
            val changed = synchronized(stateLock) {
                if (closed) return@synchronized false
                val isEnabled = enabled()
                featureEnabled = isEnabled
                loadGeneration += 1
                if (!isEnabled) {
                    browseGeneration += 1
                    _browse.value = CollectionsHubBrowseState()
                }
                _snapshot.value = if (isEnabled) {
                    val region = resolvedRegion()
                    baseSnapshot(cachedProviders(cacheScope(region, selectedProviderIds())))
                } else {
                    CollectionsHubSnapshot()
                }
                true
            }
            if (changed) _settingsChanges.tryEmit(Unit)
        }
    }

    init {
        preferences.observe(listener)
    }

    suspend fun load() = loadMutex.withLock {
        val generation = synchronized(stateLock) {
            if (closed) return@withLock
            if (!featureEnabled) {
                loadGeneration += 1
                browseGeneration += 1
                _snapshot.value = CollectionsHubSnapshot()
                _browse.value = CollectionsHubBrowseState()
                return@withLock
            }
            ++loadGeneration
        }
        val region = resolvedRegion()
        val selected = selectedProviderIds()
        val scope = cacheScope(region, selected)
        val cached = cachedProviders(scope)
        val cacheIsFresh = cached.isNotEmpty() && cacheFresh(scope)
        synchronized(stateLock) {
            if (!closed && featureEnabled && generation == loadGeneration) {
                _snapshot.value = baseSnapshot(cached).copy(streamingLoading = !cacheIsFresh)
            }
        }
        if (synchronized(stateLock) { closed || !featureEnabled || generation != loadGeneration }) return@withLock
        if (cacheIsFresh) return@withLock

        val fetched = try {
            Result.success(source.providers(region, selected))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            Result.failure(error)
        }
        synchronized(stateLock) {
            if (closed || !featureEnabled || generation != loadGeneration) return@synchronized
            if (fetched.isSuccess) {
                val providers = fetched.getOrThrow()
                cacheProviders(scope, providers)
                _snapshot.value = baseSnapshot(providers)
            } else {
                _snapshot.value = baseSnapshot(cached).copy(streamingLoadFailed = true)
            }
        }
    }

    /**
     * Resolve + cache the representative tile artwork (Discover cards, genres, decades) and republish the
     * snapshot with the imageUrls applied. Independent of the provider load (Apple runs the artwork on its
     * own tasks), cadence-cached per region, fail-soft: an all-empty fetch keeps the prior art rather than
     * blanking the tiles, which already gradient-fallback when no art is present.
     */
    suspend fun loadArtwork() = artworkMutex.withLock {
        if (synchronized(stateLock) { closed || !featureEnabled }) return@withLock
        val region = resolvedRegion()
        val cached = cachedArtwork(region)
        if (cached.byTileId.isNotEmpty()) applyArtwork(cached)
        if (artworkCacheFresh(region)) return@withLock
        val fetched = try {
            source.artwork(region, GENRES, DECADES)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            CollectionsHubArtwork()
        }
        if (fetched.byTileId.isEmpty()) return@withLock
        cacheArtwork(region, fetched)
        applyArtwork(fetched)
    }

    private fun applyArtwork(art: CollectionsHubArtwork) = synchronized(stateLock) {
        if (closed || !featureEnabled) return@synchronized
        artwork = art
        _snapshot.value = _snapshot.value.applyingArtwork(art)
    }

    private fun CollectionsHubSnapshot.applyingArtwork(art: CollectionsHubArtwork): CollectionsHubSnapshot {
        if (art.byTileId.isEmpty()) return this
        fun List<CollectionsHubTile>.arted() =
            map { tile -> art.byTileId[tile.id]?.let { tile.copy(imageUrl = it) } ?: tile }
        return copy(discover = discover.arted(), genres = genres.arted(), decades = decades.arted())
    }

    private fun cachedArtwork(scope: String): CollectionsHubArtwork {
        val raw = preferences.artworkCache(scope).encoded ?: return CollectionsHubArtwork()
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return CollectionsHubArtwork()
        val map = LinkedHashMap<String, String>()
        obj.keys().forEach { key -> obj.optString(key).takeIf(String::isNotBlank)?.let { map[key] = it } }
        return CollectionsHubArtwork(map)
    }

    private fun cacheArtwork(scope: String, art: CollectionsHubArtwork) {
        val obj = JSONObject().apply { art.byTileId.forEach { (key, value) -> put(key, value) } }
        preferences.saveArtworkCache(scope, obj.toString(), nowMillis())
    }

    private fun artworkCacheFresh(scope: String): Boolean {
        val at = preferences.artworkCache(scope).savedAtMillis
        return at > 0L && nowMillis() - at in 0 until cadenceMillis()
    }

    suspend fun open(target: CollectionsHubTarget) = browseMutex.withLock {
        if (synchronized(stateLock) { closed || !featureEnabled }) return@withLock
        val categories = categoriesFor(target)
        loadFirstPage(target, categories, categories.first())
    }

    suspend fun selectCategory(category: CollectionsHubCategory) = browseMutex.withLock {
        val current = synchronized(stateLock) {
            _browse.value.takeUnless { closed || !featureEnabled }
        } ?: return@withLock
        val target = current.target ?: return
        if (category !in current.categories || category == current.selectedCategory) return
        loadFirstPage(target, current.categories, category)
    }

    suspend fun retry() = browseMutex.withLock {
        val current = synchronized(stateLock) {
            _browse.value.takeUnless { closed || !featureEnabled }
        } ?: return@withLock
        val target = current.target ?: return@withLock
        val category = current.selectedCategory ?: return@withLock
        loadFirstPage(target, current.categories, category)
    }

    suspend fun loadMore() = browseMutex.withLock {
        beforePaginationPublication()
        val operation = synchronized(stateLock) {
            val current = _browse.value
            if (closed || !featureEnabled || current.target == null || current.selectedCategory == null ||
                current.loading || !current.hasMore
            ) {
                null
            } else {
                val generation = browseGeneration
                _browse.value = current.copy(loading = true, error = null)
                current to generation
            }
        } ?: return@withLock
        val (current, generation) = operation
        val target = current.target ?: return@withLock
        val category = current.selectedCategory ?: return@withLock
        val nextPage = current.page + 1
        val result = fetchPage(target, category, nextPage)
        synchronized(stateLock) {
            if (closed || !featureEnabled || generation != browseGeneration || _browse.value.target != target) {
                return@synchronized
            }
            _browse.value = if (result.isSuccess) {
                val page = result.getOrThrow()
                current.copy(
                    items = (current.items + page.items).distinctBy { "${it.type.id}|${it.id}" },
                    loading = false,
                    page = nextPage,
                    hasMore = page.hasMore,
                    error = null,
                )
            } else {
                current.copy(loading = false, error = CollectionsHubError.LOAD_MORE)
            }
        }
    }

    private suspend fun loadFirstPage(
        target: CollectionsHubTarget,
        categories: List<CollectionsHubCategory>,
        selected: CollectionsHubCategory,
    ) {
        val generation = synchronized(stateLock) {
            if (closed || !featureEnabled) return
            val next = ++browseGeneration
            _browse.value = CollectionsHubBrowseState(
                target = target,
                categories = categories,
                selectedCategory = selected,
                loading = true,
            )
            next
        }
        val result = fetchInitialPage(target, selected, generation)
        synchronized(stateLock) {
            if (closed || !featureEnabled || generation != browseGeneration) return@synchronized
            _browse.value = if (result.isSuccess) {
                val indexedPage = result.getOrThrow()
                CollectionsHubBrowseState(
                    target = target,
                    categories = categories,
                    selectedCategory = selected,
                    items = indexedPage.value.items,
                    loading = false,
                    page = indexedPage.number,
                    hasMore = indexedPage.value.hasMore,
                )
            } else {
                CollectionsHubBrowseState(
                    target = target,
                    categories = categories,
                    selectedCategory = selected,
                    loading = false,
                    error = CollectionsHubError.LOAD,
                )
            }
        }
    }

    private suspend fun fetchInitialPage(
        target: CollectionsHubTarget,
        category: CollectionsHubCategory,
        generation: Long,
    ): Result<IndexedCollectionsHubPage> {
        for (pageNumber in 1..MAX_INITIAL_PAGE_SCAN) {
            if (synchronized(stateLock) { closed || !featureEnabled || generation != browseGeneration }) {
                return Result.failure(IllegalStateException("Collections browse was invalidated"))
            }
            val result = fetchPage(target, category, pageNumber)
            if (result.isFailure) return Result.failure(requireNotNull(result.exceptionOrNull()))
            val page = result.getOrThrow()
            if (page.items.isNotEmpty() || !page.hasMore) {
                return Result.success(IndexedCollectionsHubPage(pageNumber, page))
            }
        }
        return Result.failure(IllegalStateException("Collections pages remained filtered at the scan limit"))
    }

    fun closeBrowse() = synchronized(stateLock) {
        browseGeneration += 1
        _browse.value = CollectionsHubBrowseState()
    }

    fun close() {
        val shouldClose = synchronized(stateLock) {
            if (closed) return@synchronized false
            closed = true
            loadGeneration += 1
            browseGeneration += 1
            _snapshot.value = CollectionsHubSnapshot()
            _browse.value = CollectionsHubBrowseState()
            true
        }
        if (shouldClose) preferences.close()
    }

    private suspend fun fetchPage(
        target: CollectionsHubTarget,
        category: CollectionsHubCategory,
        page: Int,
    ): Result<CollectionsHubPage> = try {
        val supportsTmdb = try {
            tmdbCatalogSupported()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            false
        }
        Result.success(source.page(target, category, resolvedRegion(), page, supportsTmdb))
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

    private fun initialSnapshot(enabled: Boolean): CollectionsHubSnapshot =
        if (enabled) {
            val region = resolvedRegion()
            baseSnapshot(cachedProviders(cacheScope(region, selectedProviderIds())))
        } else {
            CollectionsHubSnapshot()
        }

    private fun baseSnapshot(providers: List<CollectionsHubTile>): CollectionsHubSnapshot {
        val art = artwork.byTileId
        return CollectionsHubSnapshot(
            enabled = true,
            discover = DiscoverList.entries.map { list ->
                val tileId = "discover:${list.wire}"
                CollectionsHubTile(
                    id = tileId,
                    title = CollectionsHubLabel.Resource(list.titleResource),
                    subtitle = CollectionsHubLabel.Resource(list.subtitleResource),
                    imageUrl = art[tileId],
                    target = CollectionsHubTarget.Discover(list),
                )
            },
            streaming = providers,
            genres = GENRES.map { genre ->
                val tileId = "genre:${genre.id}"
                CollectionsHubTile(
                    id = tileId,
                    title = CollectionsHubLabel.Resource(genre.titleResource),
                    imageUrl = art[tileId],
                    target = CollectionsHubTarget.Genre(genre),
                )
            },
            decades = DECADES.map { decade ->
                val tileId = "decade:${decade.id}"
                CollectionsHubTile(
                    id = tileId,
                    title = CollectionsHubLabel.Literal(decade.title),
                    imageUrl = art[tileId],
                    target = CollectionsHubTarget.Decade(decade),
                )
            },
        )
    }

    private fun categoriesFor(target: CollectionsHubTarget): List<CollectionsHubCategory> = when (target) {
        is CollectionsHubTarget.Discover -> BASIC_CATEGORIES
        is CollectionsHubTarget.Service, is CollectionsHubTarget.Genre -> SCOPED_CATEGORIES
        // Decade windows omit the rolling Top-This-* pills (meaningless for an old decade), mirroring Apple.
        is CollectionsHubTarget.Decade -> DECADE_CATEGORIES
    }

    // AND the RemoteConfig fleet kill-switch into the user toggle, exactly as Apple ANDs
    // `CollectionsHubModel.isAvailable` (RemoteConfig `features.collectionsHub`) with the per-surface show
    // toggle. Baked-true default => an unreachable RemoteConfig is byte-identical to shipping.
    private fun enabled(): Boolean =
        preferences.enabled() && RemoteConfig.isFeatureOn(COLLECTIONS_HUB_FEATURE_KEY, COLLECTIONS_HUB_FEATURE_DEFAULT)

    /** The Discover region override (`vortx.discover.regionPreference`) when set, else the device region. */
    private fun resolvedRegion(): String = preferences.regionOverride() ?: deviceRegion()

    private fun selectedProviderIds(): List<Int> {
        return CollectionsHubProviderPolicy.selectedProviderIds(preferences.selectedProviders(), MAX_PROVIDERS)
    }

    private fun cacheScope(region: String, selected: List<Int>): String =
        "$region.${selected.joinToString("-").ifEmpty { "auto" }}"

    private fun cadenceMillis(): Long = when (preferences.refreshCadence()) {
        "fourTimesDaily" -> 6 * 60 * 60 * 1000L
        "twiceDaily" -> 12 * 60 * 60 * 1000L
        else -> 24 * 60 * 60 * 1000L
    }

    private fun cacheFresh(scope: String): Boolean {
        val at = preferences.providerCache(scope).savedAtMillis
        return at > 0L && nowMillis() - at in 0 until cadenceMillis()
    }

    private fun cachedProviders(scope: String): List<CollectionsHubTile> {
        val raw = preferences.providerCache(scope).encoded ?: return emptyList()
        val rows = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        return buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.optInt("id", 0).takeIf { it > 0 } ?: continue
                val title = row.optString("title").takeIf(String::isNotBlank) ?: continue
                add(
                    CollectionsHubTile(
                        id = "service:$id",
                        title = CollectionsHubLabel.Literal(title),
                        imageUrl = row.optString("imageUrl").takeIf(String::isNotBlank),
                        target = CollectionsHubTarget.Service(id, title),
                    ),
                )
            }
        }.distinctBy(CollectionsHubTile::id).take(MAX_PROVIDERS)
    }

    private fun cacheProviders(scope: String, providers: List<CollectionsHubTile>) {
        val rows = JSONArray().apply {
            providers.take(MAX_PROVIDERS).forEach { tile ->
                val target = tile.target as? CollectionsHubTarget.Service ?: return@forEach
                put(JSONObject().apply {
                    put("id", target.providerId)
                    put("title", target.name)
                    tile.imageUrl?.let { put("imageUrl", it) }
                })
            }
        }
        preferences.saveProviderCache(scope, rows.toString(), nowMillis())
    }

    private companion object {
        const val MAX_PROVIDERS = 50
        const val MAX_INITIAL_PAGE_SCAN = 5

        val GENRES = listOf(
            GenreSpec("action", R.string.collections_genre_action, 28, 10759),
            GenreSpec("adventure", R.string.collections_genre_adventure, 12, 10759),
            GenreSpec("animation", R.string.collections_genre_animation, 16, 16),
            GenreSpec("comedy", R.string.collections_genre_comedy, 35, 35),
            GenreSpec("crime", R.string.collections_genre_crime, 80, 80),
            GenreSpec("documentary", R.string.collections_genre_documentary, 99, 99),
            GenreSpec("drama", R.string.collections_genre_drama, 18, 18),
            GenreSpec("family", R.string.collections_genre_family, 10751, 10751),
            GenreSpec("horror", R.string.collections_genre_horror, 27, null),
            GenreSpec("romance", R.string.collections_genre_romance, 10749, null),
            GenreSpec("science-fiction", R.string.collections_genre_science_fiction, 878, 10765),
            GenreSpec("thriller", R.string.collections_genre_thriller, 53, null),
            GenreSpec("anime", R.string.collections_genre_anime, 16, 16, keyword = 210024, originalLanguage = "ja"),
            GenreSpec("korean-drama", R.string.collections_genre_korean_drama, null, 18, originalLanguage = "ko"),
            // Apple parity (CollectionsHubModel.swift genreList): Fantasy + Mystery were the two genres the
            // Android tile set was still missing. Same TMDB genre ids as Apple (Fantasy movie 14 / tv 10765,
            // Mystery movie 9648 / tv 9648).
            GenreSpec("fantasy", R.string.collections_genre_fantasy, 14, 10765),
            GenreSpec("mystery", R.string.collections_genre_mystery, 9648, 9648),
        )
        // Browse-by-decade tiles, newest first back to the 1950s (Apple CollectionsHubModel.decadeList).
        val DECADES = listOf(
            DecadeSpec("2020s", "2020s", 2020, 2029),
            DecadeSpec("2010s", "2010s", 2010, 2019),
            DecadeSpec("2000s", "2000s", 2000, 2009),
            DecadeSpec("1990s", "1990s", 1990, 1999),
            DecadeSpec("1980s", "1980s", 1980, 1989),
            DecadeSpec("1970s", "1970s", 1970, 1979),
            DecadeSpec("1960s", "1960s", 1960, 1969),
            DecadeSpec("1950s", "1950s", 1950, 1959),
        )
        val BASIC_CATEGORIES = listOf(
            CollectionsHubCategory("movies", R.string.collections_category_movies),
            CollectionsHubCategory("shows", R.string.collections_category_shows),
        )
        val SCOPED_CATEGORIES = BASIC_CATEGORIES + listOf(
            CollectionsHubCategory("newmovies", R.string.collections_category_new_movies),
            CollectionsHubCategory("newshows", R.string.collections_category_new_shows),
            CollectionsHubCategory("topweek", R.string.collections_category_top_week),
            CollectionsHubCategory("topmonth", R.string.collections_category_top_month),
            CollectionsHubCategory("topyear", R.string.collections_category_top_year),
            CollectionsHubCategory("trending", R.string.collections_category_trending),
        )
        val DECADE_CATEGORIES = BASIC_CATEGORIES + listOf(
            CollectionsHubCategory("newmovies", R.string.collections_category_new_movies),
            CollectionsHubCategory("newshows", R.string.collections_category_new_shows),
            CollectionsHubCategory("trending", R.string.collections_category_trending),
        )
    }
}

private data class IndexedCollectionsHubPage(val number: Int, val value: CollectionsHubPage)

internal object CollectionsHubProviderPolicy {
    private val aliases = mapOf(
        2 to 350,
        119 to 9,
        384 to 1899,
        524 to 520,
        2303 to 531,
        2616 to 531,
        2304 to 531,
        122 to 2336,
        970 to 2336,
    )

    private val displayNames = mapOf(531 to "Paramount+", 2336 to "JioHotstar")

    fun canonicalId(providerId: Int): Int = aliases[providerId] ?: providerId

    fun familyMembers(providerId: Int): List<Int> {
        val canonical = canonicalId(providerId)
        return listOf(canonical) + aliases.entries
            .asSequence()
            .filter { it.value == canonical }
            .map(Map.Entry<Int, Int>::key)
            .sorted()
            .toList()
    }

    fun displayName(providerId: Int, upstream: String): String =
        displayNames[canonicalId(providerId)] ?: upstream

    fun selectedProviderIds(raw: String, limit: Int = 50): List<Int> {
        val seen = HashSet<Int>()
        return raw.split(',').mapNotNull { token ->
            val id = token.trim().toIntOrNull()?.takeIf { it > 0 } ?: return@mapNotNull null
            canonicalId(id).takeIf(seen::add)
        }.take(limit.coerceAtLeast(0))
    }

    fun serviceRegions(base: String, carried: List<String>, maxExtra: Int = 3): List<String> = buildList {
        val normalizedBase = base.uppercase(Locale.ROOT)
        add(normalizedBase)
        carried.asSequence()
            .map { it.uppercase(Locale.ROOT) }
            .filter { it.length == 2 && it != normalizedBase }
            .distinct()
            .take(maxExtra.coerceAtLeast(0))
            .forEach(::add)
    }

    fun <T> roundRobin(rows: List<List<T>>, identity: (T) -> String): List<T> {
        val output = ArrayList<T>(rows.sumOf(List<T>::size))
        val seen = HashSet<String>()
        val longest = rows.maxOfOrNull(List<T>::size) ?: 0
        repeat(longest) { index ->
            rows.forEach { row ->
                if (index < row.size && seen.add(identity(row[index]))) output += row[index]
            }
        }
        return output
    }

    /** True only when an enabled installed meta add-on declares a prefix that accepts `tmdb:` ids. */
    fun supportsTmdbCatalogItems(addons: List<InstalledAddon>): Boolean = addons.any { addon ->
        !addon.isDisabled && addon.providesMeta && tmdbPrefixes(addon.rawDescriptorJson).any { prefix ->
            prefix.isNotEmpty() && "tmdb:0".startsWith(prefix)
        }
    }

    private fun tmdbPrefixes(rawDescriptorJson: String): List<String> {
        val descriptor = runCatching { JSONObject(rawDescriptorJson) }.getOrNull() ?: return emptyList()
        val manifest = descriptor.optJSONObject("manifest") ?: return emptyList()
        val prefixes = mutableListOf<String>()
        manifest.optJSONArray("idPrefixes")?.appendStringsTo(prefixes)
        val resources = manifest.optJSONArray("resources") ?: return prefixes
        for (index in 0 until resources.length()) {
            val resource = resources.optJSONObject(index) ?: continue
            if (resource.optString("name") == "meta") {
                resource.optJSONArray("idPrefixes")?.appendStringsTo(prefixes)
            }
        }
        return prefixes
    }

    private fun JSONArray.appendStringsTo(output: MutableList<String>) {
        for (index in 0 until length()) {
            optString(index).takeIf(String::isNotBlank)?.let(output::add)
        }
    }
}

internal object CollectionsHubItemPolicy {
    fun resolvedItem(
        item: MetaItem,
        resolution: TmdbImdbResolution,
        tmdbCatalogSupported: Boolean,
    ): MetaItem? {
        val imdbId = (resolution as? TmdbImdbResolution.Resolved)?.imdbId
            ?.let(TmdbImdbResolver::ttPrefix)
        if (imdbId != null) return item.copy(id = imdbId)
        if (resolution == TmdbImdbResolution.InvalidId || !tmdbCatalogSupported) return null
        val tmdbId = canonicalTmdbId(item.id) ?: return null
        return item.copy(id = tmdbId)
    }

    private fun canonicalTmdbId(rawId: String): String? {
        val parts = rawId.lowercase(Locale.ROOT).split(":").filter(String::isNotBlank)
        if (parts.firstOrNull() != "tmdb") return null
        val numeric = parts.drop(1).firstNotNullOfOrNull { part ->
            part.toLongOrNull()?.takeIf { it in 1..Int.MAX_VALUE }
        } ?: return null
        return "tmdb:$numeric"
    }
}

/**
 * Freshness for the VortX-curated catalogs: the hub's popularity windows (the genre / service / decade
 * "Movies", "Shows" and "Trending" pills, page-rotated here). Mirrors Apple `CuratedFreshness`
 * (CollectionsHubModel.swift) so the same static ordering does not read as the identical list every open.
 * The seed is drawn ONCE per process, so the rotation is STABLE within a viewing session (scrolling,
 * paginating and returning never reorder under the user) and changes on the next app open. Deterministic
 * per catalog: the offset hashes the catalog's own query, so "1990s Movies" and "1990s Shows" rotate
 * independently. Complements (not replaces) the server-side `vxday=1` daily shuffle opt-in.
 */
internal object CuratedFreshness {
    /** One draw per process launch: fresh rotation each open, stable for the whole session. */
    private val sessionSeed: Long = java.security.SecureRandom().nextLong()

    /**
     * Pages 1..span rotate; span 4 keeps every rotated first page inside the top ~80 titles of the window,
     * so a curated row still reads as "the good stuff", just a different slice of it per open.
     */
    private const val SPAN = 4L

    /** Deterministic 0..<span page offset for a curated window (FNV-1a over the query, mixed with the seed). */
    fun pageOffset(key: String): Int = (Math.floorMod(mix(key), SPAN)).toInt()

    /**
     * Deterministic 0..<count rotation start for an already-fetched curated pool (the editorial Home rails):
     * the same seeded mix, scaled to the pool size instead of the page span. 0 on an empty pool. Mirrors
     * Apple `CuratedFreshness.rotation`.
     */
    fun rotation(key: String, count: Int): Int =
        if (count <= 0) 0 else Math.floorMod(mix(key), count.toLong()).toInt()

    /** FNV-1a over the key, mixed with the per-open session seed. */
    private fun mix(key: String): Long {
        var h = -0x340d631b7bdddcdbL // 0xcbf29ce484222325 (FNV-1a 64-bit offset basis)
        for (byte in key.toByteArray(Charsets.UTF_8)) {
            h = h xor (byte.toLong() and 0xFF)
            h *= 0x100000001b3L
        }
        h = h xor sessionSeed
        h *= 0x100000001b3L
        return h
    }
}

internal sealed class CollectionsHubTransportFailure(message: String, cause: Throwable? = null) : IOException(message, cause) {
    class Auth(val statusCode: Int) : CollectionsHubTransportFailure("Collections authorization failed (HTTP $statusCode)")
    class Http(val statusCode: Int) : CollectionsHubTransportFailure("Collections request failed (HTTP $statusCode)")
    class MalformedJson(cause: Throwable) : CollectionsHubTransportFailure("Collections response was not valid JSON", cause)
}

internal class CollectionsHubHttpTransport(
    private val baseUrl: String = COLLECTIONS_EDGE_BASE,
    private val openConnection: (URL) -> HttpURLConnection = { url ->
        url.openConnection() as HttpURLConnection
    },
) {
    suspend fun getJson(path: String): JSONObject = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = openConnection(URL(baseUrl + path)).apply {
                requestMethod = "GET"
                connectTimeout = COLLECTIONS_EDGE_TIMEOUT_MS
                readTimeout = COLLECTIONS_EDGE_TIMEOUT_MS
                useCaches = true
                setRequestProperty("accept", "application/json")
            }
            VortXEdgeAuth.sign(connection)
            when (val status = connection.responseCode) {
                HttpURLConnection.HTTP_OK -> Unit
                HttpURLConnection.HTTP_UNAUTHORIZED, HttpURLConnection.HTTP_FORBIDDEN ->
                    throw CollectionsHubTransportFailure.Auth(status)
                else -> throw CollectionsHubTransportFailure.Http(status)
            }
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            try {
                JSONObject(text)
            } catch (error: JSONException) {
                throw CollectionsHubTransportFailure.MalformedJson(error)
            }
        } finally {
            connection?.disconnect()
        }
    }
}

/** Keyless, signed catalog-edge implementation. No TMDB credential is present on the device. */
internal class EdgeCollectionsHubSource internal constructor(
    private val resolveExternalId: suspend (String, Boolean) -> TmdbImdbResolution,
    private val transport: CollectionsHubHttpTransport,
) : CollectionsHubSource {
    constructor(context: Context) : this(
        resolveExternalId = { rawId, seriesHint ->
            TmdbImdbResolver.resolveImdbIdTyped(context, rawId, seriesHint)
        },
        transport = CollectionsHubHttpTransport(),
    )

    private val providerRegionsMutex = Mutex()
    private val providerRegions = mutableMapOf<Int, List<String>>()

    override suspend fun providers(region: String, selectedProviderIds: List<Int>): List<CollectionsHubTile> = coroutineScope {
        val queryRegion = region.takeIf { selectedProviderIds.isEmpty() }
        val movie = async { providerEntries("movie", queryRegion) }
        val tv = async { providerEntries("tv", queryRegion) }
        val byCanonical = linkedMapOf<Int, ProviderEntry>()
        (movie.await() + tv.await()).forEach { incoming ->
            val canonical = CollectionsHubProviderPolicy.canonicalId(incoming.id)
            val current = byCanonical[canonical]
            val incomingIsCanonical = incoming.id == canonical
            val currentIsCanonical = current?.id == canonical
            if (current == null ||
                (!currentIsCanonical && incomingIsCanonical) ||
                (currentIsCanonical == incomingIsCanonical && incoming.priority < current.priority)
            ) {
                byCanonical[canonical] = incoming
            }
        }
        val ranked = byCanonical.entries
            .sortedWith(compareBy({ featuredProviderRank[it.key] ?: (1_000 + it.value.priority) }, { it.value.title }))
        val selectedRank = selectedProviderIds.withIndex().associate { it.value to it.index }
        val visible = if (selectedRank.isEmpty()) {
            ranked.take(MAX_PROVIDER_TILES)
        } else {
            ranked.filter { it.key in selectedRank }.sortedBy { selectedRank.getValue(it.key) }
        }
        visible.map { (canonical, entry) ->
                val title = CollectionsHubProviderPolicy.displayName(canonical, entry.title)
                CollectionsHubTile(
                    id = "service:$canonical",
                    title = CollectionsHubLabel.Literal(title),
                    imageUrl = entry.logo?.let { "$IMAGE_BASE/w185$it" },
                    target = CollectionsHubTarget.Service(canonical, title),
                )
            }
    }

    override suspend fun page(
        target: CollectionsHubTarget,
        category: CollectionsHubCategory,
        region: String,
        page: Int,
        tmdbCatalogSupported: Boolean,
    ): CollectionsHubPage {
        val raw = when (target) {
            is CollectionsHubTarget.Discover -> discover(target.list, category, region, page)
            is CollectionsHubTarget.Service -> servicePage(target.providerId, category, region, page)
            is CollectionsHubTarget.Genre -> {
                val genre = target.spec
                scopedPage(
                    category = category,
                    movieScope = scope(genre.movieGenreId, genre.keyword, genre.originalLanguage),
                    tvScope = scope(genre.tvGenreId, genre.keyword, genre.originalLanguage),
                    region = region,
                    page = page,
                )
            }
            is CollectionsHubTarget.Decade -> decadePage(target.spec, category, region, page)
        }
        return CollectionsHubPage(
            items = resolvePlayable(raw, tmdbCatalogSupported),
            hasMore = raw.isNotEmpty(),
        )
    }

    private suspend fun servicePage(
        providerId: Int,
        category: CollectionsHubCategory,
        baseRegion: String,
        page: Int,
    ): List<MetaItem> = coroutineScope {
        val family = CollectionsHubProviderPolicy.familyMembers(providerId).joinToString("%7C")
        val scope = "with_watch_providers=$family&with_watch_monetization_types=flatrate%7Cfree%7Cads"
        val regions = CollectionsHubProviderPolicy.serviceRegions(baseRegion, carriedRegions(providerId))
        val pages = regions.map { region ->
            async {
                scopedPage(
                    category = category,
                    movieScope = scope,
                    tvScope = scope,
                    region = region,
                    page = page,
                )
            }
        }.awaitAll()
        CollectionsHubProviderPolicy.roundRobin(pages) { "${it.type.id}|${it.id}" }
    }

    private suspend fun carriedRegions(providerId: Int): List<String> {
        val canonical = CollectionsHubProviderPolicy.canonicalId(providerId)
        providerRegionsMutex.withLock { providerRegions[canonical] }?.let { return it }
        val family = CollectionsHubProviderPolicy.familyMembers(canonical).toSet()
        val result = coroutineScope {
            val movie = async { transport.getJson("/watch/providers/movie") }
            val tv = async { transport.getJson("/watch/providers/tv") }
            listOf(movie.await(), tv.await())
        }
        val priorities = mutableMapOf<String, Int>()
        result.forEach { root ->
            val rows = root.resultsArray()
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                if (row.optInt("provider_id", 0) !in family) continue
                val display = row.optJSONObject("display_priorities") ?: continue
                display.keys().forEach { rawRegion ->
                    val priority = display.optInt(rawRegion, Int.MAX_VALUE)
                    val region = rawRegion.uppercase(Locale.ROOT)
                    val existing = priorities[region]
                    if (region.length == 2 && priority < (existing ?: Int.MAX_VALUE)) priorities[region] = priority
                }
            }
        }
        val resolved = priorities.entries
            .sortedWith(compareBy(Map.Entry<String, Int>::value, Map.Entry<String, Int>::key))
            .map(Map.Entry<String, Int>::key)
        providerRegionsMutex.withLock { providerRegions[canonical] = resolved }
        return resolved
    }

    private suspend fun providerEntries(media: String, region: String?): List<ProviderEntry> {
        val regionQuery = region?.let { "?watch_region=$it" }.orEmpty()
        val rows = transport.getJson("/watch/providers/$media$regionQuery").resultsArray()
        return buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.optInt("provider_id", 0).takeIf { it > 0 } ?: continue
                val title = row.optString("provider_name").takeIf(String::isNotBlank) ?: continue
                add(
                    ProviderEntry(
                        id = id,
                        title = title,
                        logo = row.optString("logo_path").takeIf(String::isNotBlank),
                        priority = row.optInt("display_priority", 999),
                    ),
                )
            }
        }
    }

    private suspend fun discover(
        list: DiscoverList,
        category: CollectionsHubCategory,
        region: String,
        page: Int,
    ): List<MetaItem> {
        val movies = category.id == "movies"
        return when (list) {
            DiscoverList.TRENDING -> list(if (movies) "/trending/movie/week" else "/trending/tv/week", if (movies) MediaType.MOVIE else MediaType.SERIES, region, page)
            DiscoverList.POPULAR -> list(if (movies) "/movie/popular" else "/tv/popular", if (movies) MediaType.MOVIE else MediaType.SERIES, region, page)
            DiscoverList.LATEST -> list(if (movies) "/movie/now_playing" else "/tv/on_the_air", if (movies) MediaType.MOVIE else MediaType.SERIES, region, page)
            DiscoverList.UPCOMING -> discover(
                media = if (movies) "movie" else "tv",
                type = if (movies) MediaType.MOVIE else MediaType.SERIES,
                extra = if (movies) {
                    "primary_release_date.gte=${LocalDate.now()}&sort_by=primary_release_date.asc"
                } else {
                    "first_air_date.gte=${LocalDate.now()}&sort_by=first_air_date.asc"
                },
                region = region,
                page = page,
            )
        }
    }

    private suspend fun scopedPage(
        category: CollectionsHubCategory,
        movieScope: String?,
        tvScope: String?,
        region: String,
        page: Int,
    ): List<MetaItem> {
        val today = LocalDate.now()
        fun append(scope: String?, suffix: String): String? = scope?.let { "$it&$suffix" }
        val (movie, tv) = when (category.id) {
            "movies" -> append(movieScope, "sort_by=popularity.desc") to null
            "shows" -> null to append(tvScope, "sort_by=popularity.desc")
            "newmovies" -> append(movieScope, "sort_by=primary_release_date.desc&primary_release_date.lte=$today&vote_count.gte=5") to null
            "newshows" -> null to append(tvScope, "sort_by=first_air_date.desc&first_air_date.lte=$today&vote_count.gte=5")
            "topweek" -> append(movieScope, "sort_by=popularity.desc&primary_release_date.gte=${today.minusDays(7)}&primary_release_date.lte=$today&vote_count.gte=3") to
                append(tvScope, "sort_by=popularity.desc&first_air_date.gte=${today.minusDays(7)}&first_air_date.lte=$today&vote_count.gte=3")
            "topmonth" -> append(movieScope, "sort_by=popularity.desc&primary_release_date.gte=${today.minusDays(30)}&primary_release_date.lte=$today&vote_count.gte=8") to
                append(tvScope, "sort_by=popularity.desc&first_air_date.gte=${today.minusDays(30)}&first_air_date.lte=$today&vote_count.gte=8")
            "topyear" -> append(movieScope, "sort_by=popularity.desc&primary_release_date.gte=${today.minusDays(365)}&primary_release_date.lte=$today&vote_count.gte=10") to
                append(tvScope, "sort_by=popularity.desc&first_air_date.gte=${today.minusDays(365)}&first_air_date.lte=$today&vote_count.gte=10")
            else -> append(movieScope, "sort_by=popularity.desc") to append(tvScope, "sort_by=popularity.desc")
        }
        // `fresh` opts a POPULARITY window (Movies / Shows / Trending) into the per-app-open seeded page
        // rotation (CuratedFreshness). Date-sorted and Top-This-* rows keep their semantic order. When a
        // rotated first page comes back empty (a sparse window shorter than the rotation span), fall back to
        // the unrotated page 1 so rotation never blanks a working row. Mirrors Apple scopedSubs.
        val offset = if (category.id in FRESH_CATEGORY_IDS) {
            CuratedFreshness.pageOffset("${movie.orEmpty()}|${tv.orEmpty()}")
        } else {
            0
        }
        val rotated = mergedDiscover(movie, tv, region, page + offset)
        if (offset > 0 && page == 1 && rotated.isEmpty()) {
            return mergedDiscover(movie, tv, region, 1)
        }
        return rotated
    }

    /**
     * A decade's browse page: Movies / Shows / New / Trending scoped to the release-year window, with the
     * same seeded page rotation for the popularity windows. Omits the Top-This-* pills (see DECADE_CATEGORIES)
     * and, for "New", sorts by release date descending WITHIN the decade. Mirrors Apple decadeSubs.
     */
    private suspend fun decadePage(
        spec: DecadeSpec,
        category: CollectionsHubCategory,
        region: String,
        page: Int,
    ): List<MetaItem> {
        val movieWindow = "primary_release_date.gte=${spec.startYear}-01-01&primary_release_date.lte=${spec.endYear}-12-31"
        val tvWindow = "first_air_date.gte=${spec.startYear}-01-01&first_air_date.lte=${spec.endYear}-12-31"
        val (movie, tv) = when (category.id) {
            "movies" -> "$movieWindow&sort_by=popularity.desc" to null
            "shows" -> null to "$tvWindow&sort_by=popularity.desc"
            "newmovies" -> "$movieWindow&sort_by=primary_release_date.desc&vote_count.gte=5" to null
            "newshows" -> null to "$tvWindow&sort_by=first_air_date.desc&vote_count.gte=5"
            else -> "$movieWindow&sort_by=popularity.desc" to "$tvWindow&sort_by=popularity.desc"
        }
        val offset = if (category.id in FRESH_CATEGORY_IDS) {
            CuratedFreshness.pageOffset("${movie.orEmpty()}|${tv.orEmpty()}")
        } else {
            0
        }
        val rotated = mergedDiscover(movie, tv, region, page + offset)
        if (offset > 0 && page == 1 && rotated.isEmpty()) {
            return mergedDiscover(movie, tv, region, 1)
        }
        return rotated
    }

    override suspend fun artwork(
        region: String,
        genres: List<GenreSpec>,
        decades: List<DecadeSpec>,
    ): CollectionsHubArtwork = coroutineScope {
        val slots = Semaphore(4) // gentle, once-daily op; kept 429-safe like Apple's batched backdrop resolve
        val requests = buildList<Pair<String, suspend () -> String?>> {
            DiscoverList.entries.forEach { list ->
                add("discover:${list.wire}" to { firstBackdrop(list.backdropListPath, region) })
            }
            genres.forEach { genre ->
                add("genre:${genre.id}" to { genreBackdrop(genre, region) })
            }
            decades.forEach { decade ->
                val window = "primary_release_date.gte=${decade.startYear}-01-01&primary_release_date.lte=${decade.endYear}-12-31&sort_by=popularity.desc"
                add("decade:${decade.id}" to { firstPoster("/discover/movie?$window&watch_region=$region&page=1") })
            }
        }
        // The permit is acquired INSIDE each async, right before the network call, so concurrency is genuinely
        // bounded (not just the await). Fail-soft: a failed lookup contributes no entry (gradient fallback).
        val resolved = requests.map { (tileId, resolve) ->
            async { tileId to slots.withPermit { resolve() } }
        }.awaitAll()
        CollectionsHubArtwork(resolved.mapNotNull { (id, url) -> url?.let { id to it } }.toMap())
    }

    private suspend fun genreBackdrop(genre: GenreSpec, region: String): String? {
        val movieScope = scope(genre.movieGenreId, genre.keyword, genre.originalLanguage)
        val tvScope = scope(genre.tvGenreId, genre.keyword, genre.originalLanguage)
        val (media, scope) = when {
            movieScope != null -> "movie" to movieScope
            tvScope != null -> "tv" to tvScope
            else -> return null
        }
        return firstBackdrop("/discover/$media?$scope&sort_by=popularity.desc&watch_region=$region&page=1", region = null)
    }

    /** First result's `backdrop_path` (w780) from a native list / discover path, or null. */
    private suspend fun firstBackdrop(path: String, region: String?): String? {
        val separator = if ('?' in path) '&' else '?'
        val query = if (region != null) "$path${separator}region=$region&page=1" else path
        val rows = runCatching { transport.getJson(query).resultsArray() }.getOrNull() ?: return null
        for (index in 0 until rows.length()) {
            val backdrop = rows.optJSONObject(index)?.optString("backdrop_path")?.takeIf(String::isNotBlank)
            if (backdrop != null) return "$IMAGE_BASE/w780$backdrop"
        }
        return null
    }

    /** First result's `poster_path` (w342) from a discover path, or null. */
    private suspend fun firstPoster(path: String): String? {
        val rows = runCatching { transport.getJson(path).resultsArray() }.getOrNull() ?: return null
        for (index in 0 until rows.length()) {
            val poster = rows.optJSONObject(index)?.optString("poster_path")?.takeIf(String::isNotBlank)
            if (poster != null) return "$IMAGE_BASE/w342$poster"
        }
        return null
    }

    private suspend fun mergedDiscover(
        movieExtra: String?,
        tvExtra: String?,
        region: String,
        page: Int,
    ): List<MetaItem> = coroutineScope {
        val movie = async {
            movieExtra?.let { discover("movie", MediaType.MOVIE, it, region, page) }.orEmpty()
        }
        val tv = async {
            tvExtra?.let { discover("tv", MediaType.SERIES, it, region, page) }.orEmpty()
        }
        interleave(movie.await(), tv.await())
    }

    private suspend fun list(path: String, type: MediaType, region: String, page: Int): List<MetaItem> {
        val separator = if ('?' in path) '&' else '?'
        val root = transport.getJson("$path${separator}region=$region&page=$page")
        return parseResults(root.resultsArray(), type)
    }

    private suspend fun discover(media: String, type: MediaType, extra: String, region: String, page: Int): List<MetaItem> {
        // vxday=1: opt these curated discover rows into the catalogs worker's daily shuffle (#6). An unknown,
        // harmless no-op until the worker ships the shuffle, then it reorders the SAME window once per day so a
        // static curated row does not read identically forever. Mirrors Apple CollectionsHubModel.mergeBuckets.
        val root = transport.getJson("/discover/$media?$extra&vxday=1&watch_region=$region&page=$page")
        return parseResults(root.resultsArray(), type)
    }

    private fun parseResults(rows: JSONArray, type: MediaType): List<MetaItem> {
        return buildList {
            for (index in 0 until rows.length()) {
                val row = rows.optJSONObject(index) ?: continue
                val id = row.optInt("id", 0).takeIf { it > 0 } ?: continue
                val name = (row.optString("title").ifBlank { row.optString("name") }).takeIf(String::isNotBlank)
                    ?: continue
                val date = row.optString("release_date").ifBlank { row.optString("first_air_date") }
                add(
                    MetaItem(
                        id = "tmdb:${if (type == MediaType.SERIES) "tv" else "movie"}:$id",
                        type = type,
                        name = name,
                        poster = row.optString("poster_path").takeIf(String::isNotBlank)?.let { "$IMAGE_BASE/w342$it" },
                        year = date.take(4).takeIf { it.length == 4 },
                        description = row.optString("overview").takeIf(String::isNotBlank),
                        background = row.optString("backdrop_path").takeIf(String::isNotBlank)?.let { "$IMAGE_BASE/w780$it" },
                    ),
                )
            }
        }
    }

    private suspend fun resolvePlayable(
        items: List<MetaItem>,
        tmdbCatalogSupported: Boolean,
    ): List<MetaItem> = coroutineScope {
        val slots = Semaphore(6)
        items.take(40).mapIndexed { index, item ->
            async {
                index to slots.withPermit {
                    CollectionsHubItemPolicy.resolvedItem(
                        item = item,
                        resolution = resolveExternalId(item.id, item.type == MediaType.SERIES),
                        tmdbCatalogSupported = tmdbCatalogSupported,
                    )
                }
            }
        }.awaitAll().sortedBy { it.first }.mapNotNull { it.second }
    }

    private fun interleave(first: List<MetaItem>, second: List<MetaItem>): List<MetaItem> {
        val out = ArrayList<MetaItem>(first.size + second.size)
        val seen = HashSet<String>()
        repeat(maxOf(first.size, second.size)) { index ->
            if (index < first.size && seen.add(first[index].id)) out += first[index]
            if (index < second.size && seen.add(second[index].id)) out += second[index]
        }
        return out
    }

    private fun scope(genreId: Int?, keyword: Int?, language: String?): String? {
        val values = buildList {
            genreId?.let { add("with_genres=$it") }
            keyword?.let { add("with_keywords=$it") }
            language?.let { add("with_original_language=$it") }
        }
        return values.takeIf(List<String>::isNotEmpty)?.joinToString("&")
    }

    private fun JSONObject.resultsArray(): JSONArray =
        try {
            getJSONArray("results")
        } catch (error: JSONException) {
            throw CollectionsHubTransportFailure.MalformedJson(error)
        }

    private companion object {
        const val IMAGE_BASE = "https://image.tmdb.org/t/p"
        const val MAX_PROVIDER_TILES = 50

        // The popularity windows that opt into the per-app-open seeded page rotation (CuratedFreshness). The
        // date-sorted ("newmovies"/"newshows") and rolling Top-This-* rows keep their semantic order.
        val FRESH_CATEGORY_IDS = setOf("movies", "shows", "trending")

        val featuredProviderRank = mapOf(
            8 to 0,
            9 to 1,
            337 to 2,
            1899 to 3,
            15 to 4,
            350 to 5,
            531 to 6,
            386 to 7,
            283 to 8,
            344 to 9,
            430 to 10,
            2336 to 11,
            43 to 12,
            526 to 14,
            520 to 15,
            38 to 16,
            73 to 17,
            300 to 18,
            11 to 19,
            232 to 34,
            237 to 35,
        )
    }

    private data class ProviderEntry(
        val id: Int,
        val title: String,
        val logo: String?,
        val priority: Int,
    )
}
