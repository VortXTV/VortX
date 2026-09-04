package com.vortx.android.data

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.AdvancedDiscoverFilters
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

internal interface CatalogPreferencesPersistence {
    fun read(): String?
    fun write(value: String?)
}

private class SharedPreferencesCatalogPersistence(
    private val preferences: SharedPreferences,
) : CatalogPreferencesPersistence {
    override fun read(): String? = preferences.getString(CatalogPreferencesStore.FILTERS_KEY, null)

    override fun write(value: String?) {
        preferences.edit().apply {
            if (value == null) remove(CatalogPreferencesStore.FILTERS_KEY) else putString(CatalogPreferencesStore.FILTERS_KEY, value)
        }.apply()
    }
}

private class MemoryCatalogPreferencesPersistence(
    private var value: String? = null,
) : CatalogPreferencesPersistence {
    override fun read(): String? = value
    override fun write(value: String?) {
        this.value = value
    }
}

/** On-device persistence for the client-side Discover filters, using Apple's JSON field names. */
class CatalogPreferencesStore internal constructor(
    private val persistence: CatalogPreferencesPersistence,
) {
    private val _filters = MutableStateFlow(decode(persistence.read()))
    val filters: StateFlow<AdvancedDiscoverFilters> = _filters.asStateFlow()

    fun setFilters(filters: AdvancedDiscoverFilters) {
        if (_filters.value == filters) return
        _filters.value = filters
        persistence.write(if (filters.isActive) encode(filters) else null)
        ProfileStore.sharedOrNull()?.captureDiscovery()
    }

    fun clearFilters() = setFilters(AdvancedDiscoverFilters.EMPTY)

    fun reload() {
        _filters.value = decode(persistence.read())
    }

    companion object {
        const val FILTERS_KEY = "vortx.discover.filters"

        @Volatile private var instance: CatalogPreferencesStore? = null

        fun shared(context: Context): CatalogPreferencesStore = instance ?: synchronized(this) {
            instance ?: CatalogPreferencesStore(
                SharedPreferencesCatalogPersistence(
                    context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE),
                ),
            ).also { store ->
                ProfileStore.sharedOrNull()?.addSwitchListener(store::reload)
                instance = store
            }
        }

        internal fun inMemory(initial: AdvancedDiscoverFilters = AdvancedDiscoverFilters.EMPTY): CatalogPreferencesStore =
            CatalogPreferencesStore(
                MemoryCatalogPreferencesPersistence(if (initial.isActive) encode(initial) else null),
            )

        internal fun encode(filters: AdvancedDiscoverFilters): String = JSONObject().apply {
            put("includedGenres", filters.includedGenres.toJsonArray())
            put("excludedGenres", filters.excludedGenres.toJsonArray())
            filters.minYear?.let { put("minYear", it) }
            filters.maxYear?.let { put("maxYear", it) }
            put("ageRatings", filters.ageRatings.toJsonArray())
            filters.minMinutes?.let { put("minMinutes", it) }
            filters.maxMinutes?.let { put("maxMinutes", it) }
            filters.minSeasons?.let { put("minSeasons", it) }
            filters.maxSeasons?.let { put("maxSeasons", it) }
            put("upcomingOnly", filters.upcomingOnly)
        }.toString()

        internal fun decode(raw: String?): AdvancedDiscoverFilters {
            if (raw.isNullOrBlank()) return AdvancedDiscoverFilters.EMPTY
            return runCatching {
                val json = JSONObject(raw)
                AdvancedDiscoverFilters(
                    includedGenres = json.optJSONArray("includedGenres").toStringSet(),
                    excludedGenres = json.optJSONArray("excludedGenres").toStringSet(),
                    minYear = json.optionalInt("minYear"),
                    maxYear = json.optionalInt("maxYear"),
                    ageRatings = json.optJSONArray("ageRatings").toStringSet(),
                    minMinutes = json.optionalInt("minMinutes"),
                    maxMinutes = json.optionalInt("maxMinutes"),
                    minSeasons = json.optionalInt("minSeasons"),
                    maxSeasons = json.optionalInt("maxSeasons"),
                    upcomingOnly = json.optBoolean("upcomingOnly", false),
                )
            }.getOrDefault(AdvancedDiscoverFilters.EMPTY)
        }
    }
}

private fun Set<String>.toJsonArray(): JSONArray = JSONArray().also { array ->
    sorted().forEach(array::put)
}

private fun JSONArray?.toStringSet(): Set<String> {
    if (this == null) return emptySet()
    return buildSet {
        for (index in 0 until length()) {
            optString(index).takeIf(String::isNotBlank)?.let(::add)
        }
    }
}

private fun JSONObject.optionalInt(key: String): Int? =
    if (has(key) && !isNull(key)) optInt(key) else null
