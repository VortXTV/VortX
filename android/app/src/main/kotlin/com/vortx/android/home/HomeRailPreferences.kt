package com.vortx.android.home

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.Catalog
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray

enum class HomeRail(val key: String, val title: String) {
    COLLECTIONS_HUB("collectionsHub", "Collections"),
    TOP_PICKS("topPicks", "Top Picks for you"),
    BECAUSE_YOU_WATCHED("becauseYouWatched", "Because You Watched"),
    TRAKT_WATCHLIST("traktWatchlist", "Trakt Watchlist"),
    SIMKL_WATCHLIST("simklWatchlist", "SIMKL Watchlist"),
    MEDIA_SERVERS("mediaServers", "Media Servers"),
    UPCOMING_EPISODES("upcomingEpisodes", "Upcoming Episodes"),
    UPCOMING_MOVIES("upcomingMovies", "Upcoming Movies"),
    ADDON_CATALOGS("addonCatalogs", "Add-on Catalogs"),
    EDITORIAL_COLLECTIONS("editorialCollections", "Editorial Collections"),
    IMPORTED_LISTS("importedLists", "Imported Lists");

    val catalogId: String get() = "$SECTION_CATALOG_PREFIX$key"

    companion object {
        const val CONTINUE_CATALOG_ID = "continue"
        private const val SECTION_CATALOG_PREFIX = "vortx.home."

        val phoneDefaultOrder = listOf(
            COLLECTIONS_HUB,
            TOP_PICKS,
            BECAUSE_YOU_WATCHED,
            TRAKT_WATCHLIST,
            SIMKL_WATCHLIST,
            MEDIA_SERVERS,
            UPCOMING_EPISODES,
            UPCOMING_MOVIES,
            ADDON_CATALOGS,
            EDITORIAL_COLLECTIONS,
            IMPORTED_LISTS,
        )

        val tvDefaultOrder = listOf(
            COLLECTIONS_HUB,
            TOP_PICKS,
            BECAUSE_YOU_WATCHED,
            TRAKT_WATCHLIST,
            SIMKL_WATCHLIST,
            MEDIA_SERVERS,
            IMPORTED_LISTS,
            UPCOMING_EPISODES,
            UPCOMING_MOVIES,
            ADDON_CATALOGS,
        )

        fun forCatalog(catalog: Catalog): HomeRail =
            entries.firstOrNull { catalog.id == it.catalogId } ?: ADDON_CATALOGS

        fun fromKey(key: String): HomeRail? = entries.firstOrNull { it.key == key }
    }
}

enum class HomeRailSurface { PHONE, TV }

data class HomeRailLayout(
    val order: List<HomeRail>,
    val hidden: Set<HomeRail>,
)

internal object HomeRailPolicy {
    fun normalizedOrder(savedKeys: List<String>, defaults: List<HomeRail>): List<HomeRail> {
        if (savedKeys.isEmpty()) return defaults
        val allowed = defaults.toSet()
        val saved = savedKeys.mapNotNull(HomeRail::fromKey).filter { it in allowed }.distinct()
        return saved + defaults.filterNot(saved::contains)
    }

    fun arrangeCatalogs(
        catalogs: List<Catalog>,
        defaults: List<HomeRail>,
        layout: HomeRailLayout,
    ): List<Catalog> {
        val pinned = catalogs.filter { it.id == HomeRail.CONTINUE_CATALOG_ID }
        val groups = catalogs
            .filterNot { it.id == HomeRail.CONTINUE_CATALOG_ID }
            .groupBy(HomeRail::forCatalog)
        return buildList {
            addAll(pinned)
            layout.order.ifEmpty { defaults }.forEach { rail ->
                if (rail !in layout.hidden) addAll(groups[rail].orEmpty())
            }
        }
    }

    fun move(order: List<HomeRail>, rail: HomeRail, delta: Int): List<HomeRail>? {
        if (delta == 0) return null
        val from = order.indexOf(rail)
        if (from < 0) return null
        val to = from + delta
        if (to !in order.indices) return null
        return order.toMutableList().apply { add(to, removeAt(from)) }
    }
}

class HomeRailPreferences private constructor(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences(
        com.vortx.android.profile.ProfileStore.PREFS_FILE,
        Context.MODE_PRIVATE,
    )
    private val lock = Any()
    private val _state = kotlinx.coroutines.flow.MutableStateFlow(readLayout())
    val state = _state.asStateFlow()

    private val preferenceListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == ORDER_KEY || key == HIDDEN_KEY) reload()
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(preferenceListener)
    }

    fun defaults(surface: HomeRailSurface): List<HomeRail> = when (surface) {
        HomeRailSurface.PHONE -> HomeRail.phoneDefaultOrder
        HomeRailSurface.TV -> HomeRail.tvDefaultOrder
    }

    fun ordered(surface: HomeRailSurface): List<HomeRail> = synchronized(lock) {
        val layout = currentLayoutLocked()
        HomeRailPolicy.normalizedOrder(layout.order.map(HomeRail::key), defaults(surface))
    }

    fun arrange(catalogs: List<Catalog>, surface: HomeRailSurface, layout: HomeRailLayout): List<Catalog> =
        HomeRailPolicy.arrangeCatalogs(
            catalogs = catalogs,
            defaults = defaults(surface),
            layout = layout.copy(
                order = HomeRailPolicy.normalizedOrder(layout.order.map(HomeRail::key), defaults(surface)),
            ),
        )

    fun setHidden(rail: HomeRail, hidden: Boolean) = synchronized(lock) {
        val current = currentLayoutLocked()
        val next = current.hidden.toMutableSet().apply {
            if (hidden) add(rail) else remove(rail)
        }
        prefs.edit().putStringSet(HIDDEN_KEY, next.mapTo(mutableSetOf(), HomeRail::key)).apply()
        _state.value = current.copy(hidden = next)
    }

    fun setOrder(rails: List<HomeRail>) = synchronized(lock) {
        val current = currentLayoutLocked()
        val normalized = rails.distinct()
        prefs.edit().putString(ORDER_KEY, JSONArray(normalized.map(HomeRail::key)).toString()).apply()
        _state.value = current.copy(order = normalized)
    }

    fun move(rail: HomeRail, delta: Int, surface: HomeRailSurface) {
        val next = HomeRailPolicy.move(ordered(surface), rail, delta) ?: return
        setOrder(next)
    }

    fun reset() = synchronized(lock) {
        prefs.edit().remove(ORDER_KEY).remove(HIDDEN_KEY).apply()
        _state.value = HomeRailLayout(emptyList(), emptySet())
    }

    fun reload() = synchronized(lock) {
        _state.value = readLayout()
    }

    private fun currentLayoutLocked(): HomeRailLayout = _state.value

    private fun readLayout(): HomeRailLayout {
        val order = runCatching {
            val array = JSONArray(prefs.getString(ORDER_KEY, "[]"))
            buildList {
                for (index in 0 until array.length()) {
                    HomeRail.fromKey(array.optString(index))?.let(::add)
                }
            }.distinct()
        }.getOrDefault(emptyList())
        val hidden = prefs.getStringSet(HIDDEN_KEY, emptySet())
            .orEmpty()
            .mapNotNull(HomeRail::fromKey)
            .toSet()
        return HomeRailLayout(order, hidden)
    }

    companion object {
        const val ORDER_KEY = "vortx.home.railOrder"
        const val HIDDEN_KEY = "vortx.home.railHidden"

        @Volatile private var instance: HomeRailPreferences? = null

        fun shared(context: Context): HomeRailPreferences = instance ?: synchronized(this) {
            instance ?: HomeRailPreferences(context).also { instance = it }
        }
    }
}
