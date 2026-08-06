package com.vortx.android.library

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.MediaType
import com.vortx.android.model.MetaItem
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Profile-local want-to-watch ledger, separate from the account library and remote integrations. */
class WatchlistStore private constructor(
    private val prefs: SharedPreferences,
    private val activeProfileId: () -> String,
    registerProfileSwitch: ((() -> Unit) -> Unit),
) {
    private val _items = MutableStateFlow<List<MetaItem>>(emptyList())
    val items: StateFlow<List<MetaItem>> = _items.asStateFlow()

    init {
        reload()
        registerProfileSwitch(::reload)
    }

    @Synchronized
    fun reload() {
        _items.value = WatchlistCodec.decode(prefs.getString(storageKey(), null))
            .map(WatchlistEntry::toMetaItem)
    }

    @Synchronized
    fun isWatchlisted(id: String): Boolean = _items.value.any { it.id == id }

    /** Returns the new membership state. Unsafe synthetic ids are rejected. */
    @Synchronized
    fun toggle(item: MetaItem): Boolean {
        if (!isSafeId(item.id)) return false
        val current = WatchlistCodec.decode(prefs.getString(storageKey(), null)).toMutableList()
        val existing = current.indexOfFirst { it.id == item.id }
        val nowWatchlisted = existing < 0
        if (existing >= 0) {
            current.removeAt(existing)
        } else {
            current += WatchlistEntry(
                id = item.id,
                type = if (item.type == MediaType.SERIES) MediaType.SERIES.id else MediaType.MOVIE.id,
                name = item.name.takeIf(String::isNotBlank),
                poster = item.poster?.takeIf(String::isNotBlank),
                addedAt = System.currentTimeMillis() / 1000.0,
            )
        }
        val bounded = current.sortedByDescending(WatchlistEntry::addedAt).take(MAX_ENTRIES)
        prefs.edit().putString(storageKey(), WatchlistCodec.encode(bounded)).apply()
        _items.value = bounded.map(WatchlistEntry::toMetaItem)
        return nowWatchlisted
    }

    private fun storageKey(): String = "$KEY_PREFIX.${activeProfileId()}"

    internal companion object {
        private const val KEY_PREFIX = "vortx.watchlist"
        private const val MAX_ENTRIES = 1000

        internal fun isSafeId(id: String): Boolean = id.startsWith("tt") || id.startsWith("tmdb")

        @Volatile
        private var instance: WatchlistStore? = null

        fun shared(context: Context): WatchlistStore = instance ?: synchronized(this) {
            instance ?: WatchlistStore(
                prefs = context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE),
                activeProfileId = { ProfileStore.shared.activeProfileId },
                registerProfileSwitch = { ProfileStore.shared.addSwitchListener(it) },
            ).also { instance = it }
        }
    }
}

internal data class WatchlistEntry(
    val id: String,
    val type: String,
    val name: String?,
    val poster: String?,
    val addedAt: Double,
) {
    fun toMetaItem(): MetaItem = MetaItem(
        id = id,
        type = MediaType.fromId(type),
        name = name ?: id,
        poster = poster,
    )
}

internal object WatchlistCodec {
    fun decode(raw: String?): List<WatchlistEntry> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val array = JSONArray(raw)
            buildList {
                for (index in 0 until array.length()) {
                    val value = array.optJSONObject(index) ?: continue
                    val id = value.optString("id").takeIf(WatchlistStore::isSafeId) ?: continue
                    add(
                        WatchlistEntry(
                            id = id,
                            type = if (value.optString("type") == MediaType.SERIES.id) {
                                MediaType.SERIES.id
                            } else {
                                MediaType.MOVIE.id
                            },
                            name = value.optNullableString("name"),
                            poster = value.optNullableString("poster"),
                            addedAt = value.optDouble("addedAt").takeIf(Double::isFinite) ?: 0.0,
                        ),
                    )
                }
            }.sortedByDescending(WatchlistEntry::addedAt).distinctBy(WatchlistEntry::id)
        }.getOrDefault(emptyList())
    }

    fun encode(entries: List<WatchlistEntry>): String = JSONArray().apply {
        entries.forEach { entry ->
            put(
                JSONObject().apply {
                    put("id", entry.id)
                    put("type", entry.type)
                    put("name", entry.name ?: JSONObject.NULL)
                    put("poster", entry.poster ?: JSONObject.NULL)
                    put("addedAt", entry.addedAt)
                },
            )
        }
    }.toString()
}

private fun JSONObject.optNullableString(key: String): String? =
    if (!has(key) || isNull(key)) null else optString(key).takeIf(String::isNotBlank)
