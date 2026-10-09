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
    val showCollectionsHome: Boolean? = null,
    val showCollectionsDiscover: Boolean? = null,
    val continueWatchingSource: String? = null,
    val continueWatchingWindow: String? = null,
)

/** Migration requires both exact acknowledged records and a passive, connected account witness. */
internal fun eligibleLegacyContinueWatchingMigration(
    previous: UserProfile?, incoming: UserProfile?, acknowledgedProfileID: String,
    flatSourcePresent: Boolean, legacyEnabled: Boolean, accountAndSessionKnown: Boolean,
): Boolean = previous != null && incoming != null && previous.id == acknowledgedProfileID && incoming.id == acknowledgedProfileID &&
    previous.usesEngineHistory && incoming.usesEngineHistory && previous.discovery?.continueWatchingSource == null &&
    incoming.discovery?.continueWatchingSource == null && !flatSourcePresent && legacyEnabled && accountAndSessionKnown

internal fun <T> sameContinueWatchingMigrationAuthority(previousAccount: T?, currentAccount: T?, previousSession: Long?, currentSession: Long?): Boolean =
    previousAccount != null && previousAccount == currentAccount && previousSession != null && previousSession == currentSession

/** A failed checkpoint retains only this exact qualified capture; it cannot adopt another owner on retry. */
internal class ContinueWatchingMigrationCheckpoint<T> {
    data class Witness<T>(val profileID: String, val account: T, val traktEpoch: Long)
    var witness: Witness<T>? = null
        private set
    private var pendingDiscovery: ProfileDiscoveryPreferences? = null
    fun capture(profileID: String, account: T, epoch: Long) { pendingDiscovery = null; witness = Witness(profileID, account, epoch) }
    fun retire() { witness = null; pendingDiscovery = null }
    /** Retained only with this witness, so a later fresh projection cannot erase a failed local edit. */
    fun retainDiscoveryCapture(profile: UserProfile, flat: ProfileDiscoveryPreferences) {
        if (witness?.profileID == profile.id)
            pendingDiscovery = pendingContinueWatchingDiscoveryCapture(profile, flat).discovery
    }
    fun attempt(incoming: UserProfile?, profileID: String, account: T?, epoch: Long?,
        save: (UserProfile) -> NativeProfileGateway.Projection?, authorityIsCurrent: () -> Boolean,
        readbackIsCurrent: (NativeProfileGateway.Projection) -> Boolean = { true }): NativeProfileGateway.Projection? {
        val captured = witness ?: return null
        if (incoming == null || profileID != captured.profileID || incoming.id != captured.profileID ||
            account != captured.account || epoch != captured.traktEpoch || incoming.discovery?.continueWatchingSource != null) {
            retire(); return null
        }
        val discovery = pendingDiscovery ?: incoming.discovery ?: ProfileDiscoveryPreferences()
        val edited = incoming.copy(discovery = discovery.copy(
            continueWatchingSource = "trakt", continueWatchingWindow = discovery.continueWatchingWindow ?: "20"))
        val saved = runCatching { if (authorityIsCurrent()) save(edited) else null }.getOrNull()
        if (!authorityIsCurrent()) { retire(); return null }
        if (saved?.activeID != captured.profileID || saved.profiles.firstOrNull { it.id == captured.profileID }?.discovery != edited.discovery || !readbackIsCurrent(saved)) return null
        if (!authorityIsCurrent()) { retire(); return null }
        retire(); return saved
    }
}

internal fun pendingContinueWatchingDiscoveryCapture(profile: UserProfile, flat: ProfileDiscoveryPreferences): UserProfile =
    profile.copy(discovery = flat.copy(continueWatchingSource = null, continueWatchingWindow = profile.discovery?.continueWatchingWindow))

/** Bridges a profile's snapshot to the legacy flat keys consumed by Android UI and engine code. */
internal object ProfileDiscoveryPreferencesStore {
    const val HIDDEN_CATALOGS_KEY = "stremiox.catalog.hidden"
    const val CATALOG_ORDER_KEY = "stremiox.catalog.order"
    const val PROVIDER_ORDER_KEY = COLLECTIONS_PROVIDER_ORDER_KEY
    const val SHOW_COLLECTIONS_HOME_KEY = "vortx.home.showCollectionsHub"
    const val SHOW_COLLECTIONS_DISCOVER_KEY = "vortx.discover.showCollectionsHub"

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
        SHOW_COLLECTIONS_HOME_KEY,
        SHOW_COLLECTIONS_DISCOVER_KEY,
        com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY,
        com.vortx.android.home.CONTINUE_WATCHING_WINDOW_KEY,
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
        showCollectionsHome = prefs.getBoolean(SHOW_COLLECTIONS_HOME_KEY, true),
        showCollectionsDiscover = prefs.getBoolean(SHOW_COLLECTIONS_DISCOVER_KEY, true),
        continueWatchingSource = prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY, "local"),
        continueWatchingWindow = prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_WINDOW_KEY, "20"),
    )

    fun apply(snapshot: ProfileDiscoveryPreferences?, resetUnset: Boolean, prefs: SharedPreferences) {
        val e = prefs.edit()
        val nextSource = snapshot?.continueWatchingSource ?: if (resetUnset) "local" else prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY, null)
        val nextWindow = snapshot?.continueWatchingWindow ?: if (resetUnset) "20" else prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_WINDOW_KEY, null)
        if (nextSource != prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY, null) ||
            nextWindow != prefs.getString(com.vortx.android.home.CONTINUE_WATCHING_WINDOW_KEY, null))
            com.vortx.android.home.ContinueWatchingSelectionRevision.changed()
        listOf(com.vortx.android.home.CONTINUE_WATCHING_SOURCE_KEY to (snapshot?.continueWatchingSource to "local"),
            com.vortx.android.home.CONTINUE_WATCHING_WINDOW_KEY to (snapshot?.continueWatchingWindow to "20")).forEach { (key, pair) ->
            if (pair.first != null) e.putString(key, pair.first) else if (resetUnset) e.putString(key, pair.second)
        }
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
        listOf(SHOW_COLLECTIONS_HOME_KEY to snapshot?.showCollectionsHome,
            SHOW_COLLECTIONS_DISCOVER_KEY to snapshot?.showCollectionsDiscover).forEach { (key, value) ->
            if (value != null) e.putBoolean(key, value) else if (resetUnset) e.putBoolean(key, true)
        }
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
