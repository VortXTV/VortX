package com.vortx.android.profile

import android.content.SharedPreferences
import com.vortx.android.data.CatalogPreferencesStore
import com.vortx.android.home.COLLECTIONS_SELECTED_PROVIDERS_KEY
import com.vortx.android.home.COLLECTIONS_PROVIDER_ORDER_KEY
import com.vortx.android.home.DISCOVER_HIDDEN_CATEGORIES_KEY
import com.vortx.android.home.DISCOVER_REGION_PREFERENCE_KEY
import com.vortx.android.ui.prefs.TabBarPrefs
import java.util.Base64
import java.util.Locale

/**
 * Profile-owned Discover and catalog state. Field names intentionally mirror Apple's
 * `ProfileDiscoveryPreferences` Codable payload, including nullable capture markers.
 */
data class ProfileDiscoveryPreferences(
    val hiddenCatalogs: List<String>? = null,
    val catalogOrder: List<String>? = null,
    val hiddenHubCategories: List<String>? = null,
    val regionOverrideCaptured: Boolean? = null,
    val regionOverride: String? = null,
    val filtersCaptured: Boolean? = null,
    /** Base64 of the existing UTF-8 Discover-filter JSON, matching Swift Data JSON encoding. */
    val filtersData: String? = null,
    val selectedProviders: List<Int>? = null,
    val providerOrder: List<Int>? = null,
    val tabVisibilityCaptured: Boolean? = null,
    val hideLiveTab: Boolean? = null,
    val hideDiscoverTab: Boolean? = null,
    val hideLibraryTab: Boolean? = null,
    val hideSearchTab: Boolean? = null,
)

/** Bridges a profile's snapshot to the legacy flat keys consumed by Android UI and engine code. */
internal object ProfileDiscoveryPreferencesStore {
    const val HIDDEN_CATALOGS_KEY = "stremiox.catalog.hidden"
    const val CATALOG_ORDER_KEY = "stremiox.catalog.order"
    const val PROVIDER_ORDER_KEY = COLLECTIONS_PROVIDER_ORDER_KEY

    /** These keys project ONLY the active viewer and must never independently ride account settings sync. */
    val activeProjectionKeys: Set<String> = setOf(
        HIDDEN_CATALOGS_KEY,
        CATALOG_ORDER_KEY,
        DISCOVER_HIDDEN_CATEGORIES_KEY,
        DISCOVER_REGION_PREFERENCE_KEY,
        CatalogPreferencesStore.FILTERS_KEY,
        COLLECTIONS_SELECTED_PROVIDERS_KEY,
        PROVIDER_ORDER_KEY,
        TabBarPrefs.HIDE_LIVE_KEY,
        TabBarPrefs.HIDE_DISCOVER_KEY,
        TabBarPrefs.HIDE_LIBRARY_KEY,
        TabBarPrefs.HIDE_SEARCH_KEY,
    )

    fun capture(prefs: SharedPreferences): ProfileDiscoveryPreferences = ProfileDiscoveryPreferences(
        hiddenCatalogs = prefs.getStringSet(HIDDEN_CATALOGS_KEY, emptySet()).orEmpty().sorted(),
        catalogOrder = prefs.getString(CATALOG_ORDER_KEY, "")
            .orEmpty().split(',').filter(String::isNotBlank),
        hiddenHubCategories = prefs.getStringSet(DISCOVER_HIDDEN_CATEGORIES_KEY, emptySet()).orEmpty().sorted(),
        regionOverrideCaptured = true,
        regionOverride = regionOverride(prefs),
        filtersCaptured = true,
        filtersData = prefs.getString(CatalogPreferencesStore.FILTERS_KEY, null)
            ?.toByteArray(Charsets.UTF_8)?.let(Base64.getEncoder()::encodeToString),
        selectedProviders = parseIds(prefs.getString(COLLECTIONS_SELECTED_PROVIDERS_KEY, "")),
        providerOrder = parseIds(prefs.getString(PROVIDER_ORDER_KEY, "")),
        tabVisibilityCaptured = true,
        hideLiveTab = prefs.getBoolean(TabBarPrefs.HIDE_LIVE_KEY, false),
        hideDiscoverTab = prefs.getBoolean(TabBarPrefs.HIDE_DISCOVER_KEY, false),
        hideLibraryTab = prefs.getBoolean(TabBarPrefs.HIDE_LIBRARY_KEY, false),
        hideSearchTab = prefs.getBoolean(TabBarPrefs.HIDE_SEARCH_KEY, false),
    )

    fun apply(snapshot: ProfileDiscoveryPreferences?, resetUnset: Boolean, prefs: SharedPreferences) {
        val e = prefs.edit()
        applyStringSet(e, HIDDEN_CATALOGS_KEY, snapshot?.hiddenCatalogs, resetUnset)
        applyCsv(e, CATALOG_ORDER_KEY, snapshot?.catalogOrder, resetUnset)
        applyStringSet(e, DISCOVER_HIDDEN_CATEGORIES_KEY, snapshot?.hiddenHubCategories, resetUnset)
        applyNullableString(e, DISCOVER_REGION_PREFERENCE_KEY, snapshot?.regionOverrideCaptured == true || snapshot?.regionOverride != null, snapshot?.regionOverride, resetUnset) { it.uppercase(Locale.ROOT) }
        val filtersPresent = snapshot?.filtersCaptured == true || snapshot?.filtersData != null
        if (filtersPresent) {
            snapshot?.filtersData?.let { encoded ->
                runCatching { String(Base64.getDecoder().decode(encoded), Charsets.UTF_8) }.getOrNull()
            }?.let { e.putString(CatalogPreferencesStore.FILTERS_KEY, it) } ?: e.remove(CatalogPreferencesStore.FILTERS_KEY)
        } else if (resetUnset) e.remove(CatalogPreferencesStore.FILTERS_KEY)
        applyCsv(e, COLLECTIONS_SELECTED_PROVIDERS_KEY, snapshot?.selectedProviders?.map(Int::toString), resetUnset)
        applyCsv(e, PROVIDER_ORDER_KEY, snapshot?.providerOrder?.map(Int::toString), resetUnset)
        applyTab(e, TabBarPrefs.HIDE_LIVE_KEY, snapshot, snapshot?.hideLiveTab, resetUnset)
        applyTab(e, TabBarPrefs.HIDE_DISCOVER_KEY, snapshot, snapshot?.hideDiscoverTab, resetUnset)
        applyTab(e, TabBarPrefs.HIDE_LIBRARY_KEY, snapshot, snapshot?.hideLibraryTab, resetUnset)
        applyTab(e, TabBarPrefs.HIDE_SEARCH_KEY, snapshot, snapshot?.hideSearchTab, resetUnset)
        e.apply()
    }

    private fun applyStringSet(e: SharedPreferences.Editor, key: String, value: List<String>?, reset: Boolean) {
        if (value != null) e.putStringSet(key, value.toSet()) else if (reset) e.remove(key)
    }
    private fun applyCsv(e: SharedPreferences.Editor, key: String, value: List<String>?, reset: Boolean) {
        if (value != null) e.putString(key, value.joinToString(",")) else if (reset) e.remove(key)
    }
    private fun applyNullableString(e: SharedPreferences.Editor, key: String, captured: Boolean, value: String?, reset: Boolean, normalize: (String) -> String) {
        if (captured) value?.takeIf(String::isNotBlank)?.let { e.putString(key, normalize(it)) } ?: e.remove(key)
        else if (reset) e.remove(key)
    }
    private fun applyTab(
        e: SharedPreferences.Editor,
        key: String,
        snapshot: ProfileDiscoveryPreferences?,
        value: Boolean?,
        reset: Boolean,
    ) {
        if (tabFieldIsAuthoritative(snapshot?.tabVisibilityCaptured, value)) e.putBoolean(key, value ?: false)
        else if (reset) e.remove(key)
    }
    private fun regionOverride(prefs: SharedPreferences): String? = prefs.getString(DISCOVER_REGION_PREFERENCE_KEY, null)
        ?.trim()?.takeIf(String::isNotEmpty)?.uppercase(Locale.ROOT)
    private fun parseIds(value: String?): List<Int> = value.orEmpty().split(',').mapNotNull { it.trim().toIntOrNull() }

    /** Apple authority rule: a full capture owns all fields; a partial payload owns only present fields. */
    internal fun tabFieldIsAuthoritative(captured: Boolean?, value: Boolean?): Boolean = captured == true || value != null
}
