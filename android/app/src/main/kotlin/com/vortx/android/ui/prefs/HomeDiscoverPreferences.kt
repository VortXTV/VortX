package com.vortx.android.ui.prefs

import android.content.Context
import com.vortx.android.config.RemoteConfig
import com.vortx.android.config.RemoteConfigDefaults
import java.util.Locale

/**
 * Home & Discover content preferences (SET-3), the Android port of the Home/Discover section of Apple
 * `iOSSettingsView.swift:1640-1672` + `CatalogPreferences` / `HomeRailPreferences`.
 *
 * STORAGE: all keys live in [PREFS_FILE] = "vortx_settings", which is deliberately the SAME SharedPreferences
 * file as [com.vortx.android.profile.ProfileStore.PREFS_FILE]. That matters for the two keys a consumer
 * already reads: [com.vortx.android.home.CollectionsHubModel] reads `vortx.home.showCollectionsHub` and
 * `vortx.collections.refreshCadence` from that file and holds a change listener on it, so a write here
 * re-renders the hub live. Every key string + default is Apple's EXACT value so the choices ride the same
 * cross-device carriage.
 *
 * CONSUMER STATUS on Android today (the rest persist on the exact key, ready for their consumer):
 *   - `vortx.home.showCollectionsHub`      -> CollectionsHubModel (WIRED, live).
 *   - `vortx.collections.refreshCadence`   -> CollectionsHubModel (WIRED, live).
 *   - `vortx.home.showCuratedRails`        -> no consumer yet (editorial-rails gate not ported).
 *   - `vortx.discover.showCollectionsHub`  -> no consumer yet (Discover hub not ported).
 *   - `vortx.mergeDiscoverSearch`          -> no consumer yet (combined surface not ported).
 *   - `vortx.detail.showFinancials`        -> no consumer yet (financials rows not ported).
 *   - `vortx.detail.spoilerSafe` / `vortx.spoilerBlur` -> no consumer yet (spoiler veil not ported).
 *   - `stremiox.catalog.hidePosterLabels`  -> no consumer yet (poster-label hide not ported).
 */
class HomeDiscoverPreferences(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    var showCuratedRails: Boolean
        get() = prefs.getBoolean(KEY_SHOW_CURATED_RAILS, true)
        set(value) { prefs.edit().putBoolean(KEY_SHOW_CURATED_RAILS, value).apply() }

    var showCollectionsHubHome: Boolean
        get() = prefs.getBoolean(KEY_SHOW_HUB_HOME, true)
        set(value) { prefs.edit().putBoolean(KEY_SHOW_HUB_HOME, value).apply() }

    var showCollectionsHubDiscover: Boolean
        get() = prefs.getBoolean(KEY_SHOW_HUB_DISCOVER, true)
        set(value) { prefs.edit().putBoolean(KEY_SHOW_HUB_DISCOVER, value).apply() }

    /** "daily" | "twiceDaily" | "fourTimesDaily" (Apple raw values). */
    var refreshCadence: String
        get() = prefs.getString(KEY_REFRESH_CADENCE, "daily") ?: "daily"
        set(value) { prefs.edit().putString(KEY_REFRESH_CADENCE, value).apply() }

    var mergeDiscoverSearch: Boolean
        get() = prefs.getBoolean(KEY_MERGE_DISCOVER_SEARCH, false)
        set(value) { prefs.edit().putBoolean(KEY_MERGE_DISCOVER_SEARCH, value).apply() }

    var showFinancials: Boolean
        get() = prefs.getBoolean(KEY_SHOW_FINANCIALS, true)
        set(value) { prefs.edit().putBoolean(KEY_SHOW_FINANCIALS, value).apply() }

    /**
     * Spoiler-safe mode. One toggle drives BOTH keys together (Apple iOSSettingsView.swift:1704-1705), so
     * turning it off fully clears the veil with no leftover default-on `vortx.spoilerBlur`.
     *
     * The fleet default (Apple `SpoilerBlurSetting`): a user who has toggled the key wins; otherwise the
     * RemoteConfig `features.spoilerBlur` fleet default applies. Baked-true default keeps a fresh install and
     * an unreachable RemoteConfig byte-identical to shipping, while a remote false can clear the veil fleet-wide.
     */
    val spoilerSafe: Boolean
        get() = if (prefs.contains(KEY_SPOILER_SAFE)) prefs.getBoolean(KEY_SPOILER_SAFE, true)
                else RemoteConfig.isFeatureOn("spoilerBlur", RemoteConfigDefaults.FEATURE_SPOILER_BLUR)

    fun setSpoilerSafe(value: Boolean) {
        prefs.edit()
            .putBoolean(KEY_SPOILER_SAFE, value)
            .putBoolean(KEY_SPOILER_BLUR, value)
            .apply()
    }

    var hidePosterLabels: Boolean
        get() = prefs.getBoolean(KEY_HIDE_POSTER_LABELS, false)
        set(value) { prefs.edit().putBoolean(KEY_HIDE_POSTER_LABELS, value).apply() }

    /**
     * Discover region override (Apple `vortx.discover.regionPreference`), stored uppercased. WIRED: the
     * collections hub reads this key and forces its TMDB watch_region to it. Empty == the device locale region.
     */
    var regionPreference: String
        get() = prefs.getString(KEY_REGION_PREFERENCE, "").orEmpty()
        set(value) {
            val normalized = value.trim().uppercase(Locale.ROOT).filter(Char::isLetter).take(2)
            prefs.edit().putString(KEY_REGION_PREFERENCE, normalized).apply()
        }

    /**
     * Per-tile / per-section Discover hidden categories (Apple `vortx.discover.hiddenCategories`). WIRED: the
     * collections hub ([com.vortx.android.home.CollectionsHubModel]) reads this key and drops the matching
     * section rows / tiles from Home and Discover; section keys ([com.vortx.android.home.HubCategoryKey]) match
     * Apple exactly, so a whole-section hide carries across devices.
     */
    var hiddenCategories: Set<String>
        get() = prefs.getStringSet(KEY_HIDDEN_CATEGORIES, emptySet()).orEmpty()
        set(value) { prefs.edit().putStringSet(KEY_HIDDEN_CATEGORIES, value.toSet()).apply() }

    companion object {
        // MUST equal com.vortx.android.profile.ProfileStore.PREFS_FILE so CollectionsHubModel sees writes.
        const val PREFS_FILE = "vortx_settings"

        const val KEY_SHOW_CURATED_RAILS = "vortx.home.showCuratedRails"
        // MUST equal com.vortx.android.home.SHOW_COLLECTIONS_HUB_KEY.
        const val KEY_SHOW_HUB_HOME = "vortx.home.showCollectionsHub"
        const val KEY_SHOW_HUB_DISCOVER = "vortx.discover.showCollectionsHub"
        // MUST equal com.vortx.android.home.COLLECTIONS_REFRESH_CADENCE_KEY.
        const val KEY_REFRESH_CADENCE = "vortx.collections.refreshCadence"
        const val KEY_MERGE_DISCOVER_SEARCH = "vortx.mergeDiscoverSearch"
        const val KEY_SHOW_FINANCIALS = "vortx.detail.showFinancials"
        const val KEY_SPOILER_SAFE = "vortx.detail.spoilerSafe"
        const val KEY_SPOILER_BLUR = "vortx.spoilerBlur"
        const val KEY_HIDE_POSTER_LABELS = "stremiox.catalog.hidePosterLabels"
        // MUST equal com.vortx.android.home.DISCOVER_REGION_PREFERENCE_KEY so the hub sees region writes.
        const val KEY_REGION_PREFERENCE = "vortx.discover.regionPreference"
        const val KEY_HIDDEN_CATEGORIES = "vortx.discover.hiddenCategories"
    }
}
