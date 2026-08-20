package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.Catalog
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URLEncoder
import java.net.URL

// Apple parity: iOSSettingsView.swift `vortx.home.showCuratedRails` gates the editorial Home rails.
internal const val SHOW_CURATED_RAILS_KEY = "vortx.home.showCuratedRails"
internal const val SHOW_CURATED_RAILS_DEFAULT = true

/** One Cinemeta catalog query backing an editorial rail. [genre] is the optional genre extra ("Drama"). */
internal data class CuratedQuery(val type: String, val catalogId: String, val genre: String? = null)

/** A static editorial collection definition: a stable id, an on-screen title, and its Cinemeta queries. */
internal data class CuratedDefinition(val id: String, val title: String, val queries: List<CuratedQuery>)

internal interface CuratedCatalogSource {
    suspend fun catalog(type: String, catalogId: String, genre: String?): List<MetaItem>
}

/**
 * Editorial Home rails (Nuvio-style): a handful of hand-curated collections ("Critically Acclaimed",
 * "Hidden Gems", ...) each backed by one or more public Cinemeta catalog queries. Kotlin port of Apple
 * `CuratedCollectionsModel` (app/SourcesShared/CuratedCollections.swift). They render BELOW the add-on
 * catalog rows on Home (the [HomeRail.EDITORIAL_COLLECTIONS] slot, phone only) and give the landing page an
 * opinionated shape even when the user has installed no extra catalog add-ons (Cinemeta alone fills them).
 *
 * Everything fails soft: each collection fetches independently, a collection that returns nothing is dropped,
 * and a fully empty result leaves the previous rails in place rather than blanking the section. The gate is
 * the exact Apple key `vortx.home.showCuratedRails`; toggling it live emits [settingsChanges].
 */
internal class CuratedCollectionsModel internal constructor(
    private val prefs: SharedPreferences,
    private val source: CuratedCatalogSource,
) {
    constructor(context: Context) : this(
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE),
        CinemetaCuratedCatalogSource(),
    )

    private val _rails = MutableStateFlow<List<Catalog>>(emptyList())
    /** The editorial rails to render, in display order, each de-duplicated and capped. Empty hides them. */
    val rails: StateFlow<List<Catalog>> = _rails.asStateFlow()

    private val _settingsChanges = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val settingsChanges: SharedFlow<Unit> = _settingsChanges.asSharedFlow()

    private val loadMutex = Mutex()

    @Volatile
    private var didLoad = false

    @Volatile
    private var closed = false

    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == SHOW_CURATED_RAILS_KEY) {
            didLoad = false // allow a rebuild on re-enable
            _settingsChanges.tryEmit(Unit)
        }
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
    }

    private fun enabled(): Boolean = prefs.getBoolean(SHOW_CURATED_RAILS_KEY, SHOW_CURATED_RAILS_DEFAULT)

    /**
     * Build the editorial rails once per process while enabled; clear them when disabled. Idempotent: a
     * second call while loaded (or disabled) is a no-op, so it is safe to call from every Home re-emit.
     */
    suspend fun load() = loadMutex.withLock {
        if (closed) return
        if (!enabled()) {
            didLoad = false
            if (_rails.value.isNotEmpty()) _rails.value = emptyList()
            return
        }
        if (didLoad) return
        val built = try {
            buildRails()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            emptyList()
        }
        if (closed || !enabled()) return
        // Keep whatever we already had on a fully empty fetch (flaky network) rather than blanking a
        // populated section; leave didLoad false so the next Home appearance retries. Mirrors Apple.
        if (built.isEmpty()) return
        _rails.value = built
        didLoad = true
    }

    fun close() {
        closed = true
        prefs.unregisterOnSharedPreferenceChangeListener(listener)
    }

    private suspend fun buildRails(): List<Catalog> = coroutineScope {
        val prefix = HomeRail.EDITORIAL_COLLECTIONS.catalogId
        DEFINITIONS.map { definition -> async { definition to fetchDefinition(definition) } }
            .awaitAll()
            .mapNotNull { (definition, items) ->
                items.takeIf(List<MetaItem>::isNotEmpty)?.let {
                    Catalog(id = "$prefix:${definition.id}", title = definition.title, items = it)
                }
            }
    }

    /**
     * Resolve one collection: run its queries in parallel, merge in declared order, de-duplicate by id, keep
     * only items with a poster (a poster-less card is a blank tile), rotate the 30-card window by a seeded
     * per-app-open offset (CuratedFreshness), and cap. A failed query contributes nothing.
     */
    private suspend fun fetchDefinition(definition: CuratedDefinition): List<MetaItem> = coroutineScope {
        val perQuery = definition.queries
            .map { query -> async { source.catalog(query.type, query.catalogId, query.genre) } }
            .awaitAll()
        val merged = ArrayList<MetaItem>()
        val seen = HashSet<String>()
        for (bucket in perQuery) {
            for (item in bucket) {
                if (item.poster.isNullOrBlank()) continue
                if (seen.add(item.id)) merged.add(item)
            }
        }
        if (merged.isEmpty()) return@coroutineScope emptyList()
        // Freshness: start the 30-card window at a seeded per-app-open rotation over the FULL merged pool, so
        // each open shows a different slice of the same editorial pool (stable for the whole session).
        val start = CuratedFreshness.rotation(definition.id, merged.size)
        val rotated = merged.subList(start, merged.size) + merged.subList(0, start)
        rotated.take(MAX_ITEMS_PER_COLLECTION)
    }

    private companion object {
        const val MAX_ITEMS_PER_COLLECTION = 30

        // Display order == on-screen order. Byte-identical queries to Apple CuratedCollectionsModel.definitions.
        val DEFINITIONS = listOf(
            CuratedDefinition(
                "curated.acclaimed",
                "Critically Acclaimed",
                listOf(CuratedQuery("movie", "imdbRating"), CuratedQuery("series", "imdbRating")),
            ),
            CuratedDefinition(
                "curated.hidden-gems",
                "Hidden Gems",
                listOf(
                    CuratedQuery("movie", "imdbRating", "Mystery"),
                    CuratedQuery("series", "imdbRating", "Crime"),
                ),
            ),
            CuratedDefinition(
                "curated.modern-classics",
                "Modern Classics",
                listOf(CuratedQuery("movie", "top", "Drama"), CuratedQuery("movie", "top", "Adventure")),
            ),
            CuratedDefinition(
                "curated.award-winners",
                "Award Winners",
                listOf(
                    CuratedQuery("movie", "imdbRating", "Drama"),
                    CuratedQuery("movie", "imdbRating", "Biography"),
                ),
            ),
        )
    }
}

/**
 * Splice the editorial rails into the Home row list. The final ordering is applied by
 * [HomeRailPreferences.arrange] (which groups every catalog by [HomeRail] and honors Customize-Home), so
 * this only needs to make the rails present; [HomeRail.forCatalog] maps their `vortx.home.editorialCollections:`
 * ids to [HomeRail.EDITORIAL_COLLECTIONS]. Mirrors the other `withXRail` helpers.
 */
internal fun withEditorialCollectionsRails(rows: List<Catalog>, editorial: List<Catalog>): List<Catalog> {
    val prefix = "${HomeRail.EDITORIAL_COLLECTIONS.catalogId}:"
    val base = rows.filterNot { it.id.startsWith(prefix) }
    if (editorial.isEmpty()) return base
    return base + editorial
}

/** Keyless Cinemeta catalog fetch. `metas` -> [MetaItem]s with real `tt` ids, so cards play via the engine. */
internal class CinemetaCuratedCatalogSource(
    private val base: String = "https://v3-cinemeta.strem.io",
) : CuratedCatalogSource {
    override suspend fun catalog(type: String, catalogId: String, genre: String?): List<MetaItem> =
        withContext(Dispatchers.IO) {
            val path = if (genre != null) {
                "/catalog/$type/$catalogId/genre=${genre.encode()}.json"
            } else {
                "/catalog/$type/$catalogId.json"
            }
            var connection: HttpURLConnection? = null
            try {
                connection = (URL(base + path).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    useCaches = true
                    setRequestProperty("accept", "application/json")
                }
                if (connection.responseCode != HttpURLConnection.HTTP_OK) return@withContext emptyList()
                val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                parseMetas(JSONObject(text).optJSONArray("metas"))
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                emptyList()
            } finally {
                connection?.disconnect()
            }
        }

    private fun parseMetas(metas: JSONArray?): List<MetaItem> {
        if (metas == null) return emptyList()
        return buildList {
            for (index in 0 until metas.length()) {
                val row = metas.optJSONObject(index) ?: continue
                val id = row.optString("id").takeIf(String::isNotBlank) ?: continue
                val name = row.optString("name").takeIf(String::isNotBlank) ?: continue
                add(
                    MetaItem(
                        id = id,
                        type = MediaType.fromId(row.optString("type", "movie")),
                        name = name,
                        poster = row.optString("poster").takeIf(String::isNotBlank),
                        year = row.optString("releaseInfo").take(4).takeIf { it.length == 4 },
                        description = row.optString("description").takeIf(String::isNotBlank),
                        background = row.optString("background").takeIf(String::isNotBlank),
                        imdbRating = row.optString("imdbRating").takeIf(String::isNotBlank),
                    ),
                )
            }
        }
    }

    private fun String.encode(): String = URLEncoder.encode(this, "UTF-8").replace("+", "%20")

    private companion object {
        const val TIMEOUT_MS = 12_000
    }
}
