package com.vortx.android.data

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.model.AddonOrder
import org.json.JSONArray

/// Local add-on preferences, the Android port of two Apple stores:
///
///  1. **Applied add-on order** (Apple `VortXSyncManager.appliedAddonOrder`, key
///     `vortx.sync.appliedAddonOrder`): the user's PRIORITY order of installed add-on transport
///     URLs, written by the Add-ons screen's drag-reorder. A reorder never rewrites the engine's
///     `profile.addons` Vec (same on Apple); it is a display/pick-order overlay consumed by
///     [com.vortx.android.engine.EngineStremioRepository.installedAddons] (list order) and
///     [com.vortx.android.engine.EngineState.parseMetaDetail] via [AddonOrder.pickByAddonOrder]
///     (the #144 localized-meta pick). Device-level, not per-profile, mirroring Apple's plain
///     UserDefaults static. The cross-device `doc.addonOrder` push is the sync lane's seam, not
///     this store's; the key name matches Apple's so that wave can dual-wire it later.
///
///  2. **Per-profile disabled add-ons** (Apple `Profiles.swift:348 toggleAddon` /
///     `ProfileStore.activeDisabledAddons`): a per-profile on/off overlay -- the add-on stays
///     INSTALLED (account-wide, engine untouched) but is excluded from this profile's Home board
///     rows and stream-source groups, exactly Apple's render-layer filter
///     (`CoreBridge.swift:978/2191/2260`). Keyed per profile id via the same provider-lambda
///     pattern [com.vortx.android.sources.SourcePinStore] uses, so one profile's toggles never
///     leak into another and no [com.vortx.android.profile.ProfileStore] file change is needed.
///
/// All URLs are normalized ([AddonOrder.normalize]: trim + lowercase) before compare/store, the
/// same normalization the applied-order rank map uses, so a toggle matches an engine descriptor
/// base regardless of case/whitespace.
class AddonPrefsStore(
    context: Context,
    private val activeProfileId: () -> String = { DEFAULT_PROFILE },
) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    // ---- applied order (device-level) ----

    /// The applied add-on priority order (transport URLs, first = highest priority), or empty when
    /// the user has never reordered -- every consumer treats empty as "engine order, unchanged".
    fun appliedOrder(): List<String> {
        val raw = prefs.getString(KEY_APPLIED_ORDER, null) ?: return emptyList()
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<String>()
        for (i in 0 until array.length()) {
            val url = array.optString(i)
            if (url.isNotBlank()) out += url
        }
        return out
    }

    /// Persist a new applied order (the reorder screen's drop). Normalized dedupe keeps the list a
    /// valid rank map (mirrors Apple `applyInAppAddonOrder`'s normalized write); an unchanged order
    /// is a no-op write.
    fun setAppliedOrder(transportUrls: List<String>) {
        val seen = mutableSetOf<String>()
        val normalizedKeep = transportUrls.filter { it.isNotBlank() && seen.add(AddonOrder.normalize(it)) }
        if (normalizedKeep == appliedOrder()) return
        prefs.edit().putString(KEY_APPLIED_ORDER, JSONArray(normalizedKeep).toString()).apply()
    }

    /// Sort [items] by the applied order, keyed by [url]: listed add-ons in the user's order first,
    /// unlisted ones after in their incoming (engine) order. Mirrors Apple
    /// `VortXSyncManager.orderedByApplied` exactly, so a newly installed add-on folds in at the end
    /// rather than disappearing.
    fun <T> orderedByApplied(items: List<T>, url: (T) -> String): List<T> {
        val order = appliedOrder()
        if (order.isEmpty()) return items
        val rank = HashMap<String, Int>(order.size)
        order.forEachIndexed { i, u -> rank[AddonOrder.normalize(u)] = i }
        // Stable sort: equal ranks (two unlisted add-ons) keep engine order between themselves.
        return items.sortedBy { rank[AddonOrder.normalize(url(it))] ?: Int.MAX_VALUE }
    }

    // ---- per-profile disabled set ----

    /// The ACTIVE profile's disabled add-on bases (normalized transport URLs). Read live on every
    /// call (SharedPreferences is an in-memory map after first load), so no reload hook is needed
    /// on a profile switch.
    fun disabledBases(): Set<String> =
        prefs.getStringSet(disabledKey(activeProfileId()), null)?.toSet() ?: emptySet()

    /// Whether [transportUrl]'s add-on is currently turned OFF for the active profile (Apple
    /// `ProfileStore.isAddonDisabledForActive`).
    fun isDisabled(transportUrl: String): Boolean =
        AddonOrder.normalize(transportUrl) in disabledBases()

    /// Turn an add-on on/off for the ACTIVE profile only. A local overlay, never an account/engine
    /// change: the add-on stays installed and stays on for every other profile (Apple
    /// `ProfileStore.toggleAddon`).
    fun setDisabled(transportUrl: String, disabled: Boolean) {
        val key = disabledKey(activeProfileId())
        val next = disabledBases().toMutableSet()
        val base = AddonOrder.normalize(transportUrl)
        val changed = if (disabled) next.add(base) else next.remove(base)
        if (!changed) return
        // Copy-on-write set: never mutate the instance getStringSet returned (a documented
        // SharedPreferences trap -- the store can hand back its own live set).
        prefs.edit().putStringSet(key, next.toSet()).apply()
    }

    private fun disabledKey(profileId: String) = "$KEY_DISABLED_PREFIX$profileId"

    companion object {
        const val DEFAULT_PROFILE = "default"
        private const val PREFS_FILE = "vortx.addon.prefs"

        /// Key name mirrors Apple's `vortx.sync.appliedAddonOrder` so the future sync wave can
        /// dual-wire the same value; the store itself is local-only.
        private const val KEY_APPLIED_ORDER = "vortx.sync.appliedAddonOrder"
        private const val KEY_DISABLED_PREFIX = "vortx.profile.disabledAddons."
    }
}
