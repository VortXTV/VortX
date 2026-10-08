package com.vortx.android.engine

import com.vortx.android.model.AddonOrder
import com.vortx.android.sources.SourcePreferencesStore
import com.vortx.android.sources.SourceType
import org.json.JSONArray
import org.json.JSONObject

/** Effective host overrides; never intersect an explicit re-enable with stale kernel disabled state. */
internal object NativeAddonPreferences {
    fun disabled(read: VortxNativeRead): Set<String> = disabledFor(read, read.owner.profileID).map(AddonOrder::normalize).toSet()
    private fun disabledFor(read: VortxNativeRead, id: String): List<String> {
        val host = read.state.optJSONObject("hostProfilePreferences")?.optJSONObject(id)
        val prefs = host?.optJSONObject("addonPreferences")
        val explicit = prefs?.optJSONArray("disabledAddonURLsOverride")
        if (explicit != null) return strings(explicit)
        if (prefs != null && id != read.owner.scope.ownerProfileID) return disabledFor(read, read.owner.scope.ownerProfileID)
        return strings(read.state.getJSONObject("roster").getJSONObject("profiles").getJSONObject(id)
            .getJSONObject("settings").getJSONArray("disabledAddons"))
    }
    fun order(read: VortxNativeRead): List<String>? {
        val host = read.state.optJSONObject("hostProfilePreferences") ?: return null
        val local = host.optJSONObject(read.owner.profileID)?.optJSONObject("addonPreferences")?.optJSONObject("rankingOverride")
        val owner = host.optJSONObject(read.owner.scope.ownerProfileID)?.optJSONObject("addonPreferences")?.optJSONObject("rankingOverride")
        // A custom ranking with no order deliberately follows the account order, not another override.
        return (if (local != null) local.optJSONArray("addonOrder") else owner?.optJSONArray("addonOrder"))?.let(::strings)?.map(AddonOrder::normalize)
    }
    fun reorderedHost(read: VortxNativeRead, urls: List<String>, shared: Boolean): JSONObject {
        val host = JSONObject(read.state.getJSONObject("hostProfilePreferences").toString())
        val raw = host.optJSONObject(read.owner.profileID)
            ?: NativeProfileAccess.projection(read).profiles.single { it.id == read.owner.profileID }.encode()
        val prefs = raw.optJSONObject("addonPreferences") ?: JSONObject().also { raw.put("addonPreferences", it) }
        val existing = prefs.optJSONObject("rankingOverride")
        if (shared || existing?.has("addonOrder") == true) {
            val owner = host.optJSONObject(read.owner.scope.ownerProfileID)
            val inherited = owner?.optJSONObject("addonPreferences")?.optJSONObject("rankingOverride")
            val playback = (if (shared) owner else raw)?.optJSONObject("playback")
            val ranking = JSONObject((existing ?: inherited ?: JSONObject()).toString())
            if (!ranking.has("sourceTypeOrder")) ranking.put("sourceTypeOrder", playback?.optJSONArray("sourceTypeOrder")
                ?: JSONArray(SourceType.allCases.map { it.storageValue }))
            if (!ranking.has("useAddonOrder")) ranking.put("useAddonOrder", playback?.optBoolean("useAddonOrder", SourcePreferencesStore.DEFAULT_USE_ADDON_ORDER)
                ?: SourcePreferencesStore.DEFAULT_USE_ADDON_ORDER)
            ranking.put("addonOrder", JSONArray(urls.map(AddonOrder::normalize).distinct()))
            prefs.put("rankingOverride", ranking)
        }
        return host.put(read.owner.profileID, raw).put("modifiedSeconds",
            maxOf(System.currentTimeMillis() / 1000.0, host.optDouble("modifiedSeconds", 0.0) + 0.001))
    }
    private fun strings(values: JSONArray) = (0 until values.length()).map(values::getString)
}
