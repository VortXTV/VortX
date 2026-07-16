package com.vortx.android.sources

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamSource
import org.json.JSONObject

/// A user-pinned source preference. The Android port of Apple `app/SourcesShared/SourcePin.swift`.
///
/// Pinning captures a stream's *signature* -- the add-on it came from, its resolution, and the add-on's
/// own bingeGroup id when present -- rather than its exact URL (which changes per episode and again every
/// time a debrid service re-resolves it). That lets one pin keep preferring the same provider + quality
/// for every episode of a show, while the player's invisible auto-failover can still hop OFF a pinned
/// source the moment it goes dead: a pin is a *preference* expressed as a large ranking bonus, never a
/// hard lock. See [StreamRanking.pinBonus].
data class SourcePin(
    /// The source group's add-on name (e.g. "Torrentio"). The only field a [SourcePinScope.GLOBAL] pin needs.
    val addon: String,
    /// Resolution label as [StreamRanking.qualityLabel] prints it: "4K" / "1080p" / "720p" / "Other".
    val quality: String,
    /// Coarse release flavor for the human label only ("Remux" / "BluRay" / "WEB" / ""), not part of the
    /// hard cross-episode match -- matching on addon+quality stays robust when a season mixes flavors.
    val flavor: String,
    /// The add-on's own same-release id, when it sets one. The strongest cross-episode key there is.
    val bingeGroup: String? = null,
) {
    /// Human label for the menu row + badge, e.g. "Torrentio · 4K · Remux".
    val label: String
        get() {
            val parts = mutableListOf(addon, quality)
            if (flavor.isNotEmpty()) parts.add(flavor)
            return parts.joinToString(" · ")
        }
}

/// Where a pin applies. [ENTRY] = this one movie or this one show (keyed by the meta id, so every episode
/// of a series shares it); [GLOBAL] = every title (a plain provider preference). Storage values match
/// Apple `SourcePinScope` raw values so a synced/backed-up blob round-trips across platforms.
enum class SourcePinScope(val storageValue: String) {
    ENTRY("entry"),
    GLOBAL("global"),
}

/// A resolved pin plus the scope it came from, handed to the ranker. Scope changes match strictness:
/// [SourcePinScope.GLOBAL] matches on add-on alone; [SourcePinScope.ENTRY] matches on bingeGroup (exact)
/// or add-on + resolution. Mirrors Apple `ResolvedPin`.
data class ResolvedPin(val pin: SourcePin, val scope: SourcePinScope)

/// The minimal title context a stream list needs to offer pinning: the meta id (the movie or the show)
/// and whether it is a series, which only changes the menu wording ("this show" vs "this movie").
/// Mirrors Apple `SourcePinContext`.
data class SourcePinContext(val metaId: String, val isSeries: Boolean) {
    val entryNoun: String get() = if (isSeries) "show" else "movie"
}

/// Per-profile store of pinned sources, persisted in [SharedPreferences] and namespaced by the active
/// profile id, the Android port of Apple `SourcePinStore`. Like Apple's store the on-disk key is
/// `stremiox.sourcePins.<profile>` so the blob lines up field-for-field with Apple for a future
/// cross-platform pin sync, and the blob lives in the shared `vortx_settings` file so it rides the same
/// settings-backup blob as [com.vortx.android.model.TrackPreferencesStore].
///
/// Per-profile scoping: [activeProfileId] defaults to [DEFAULT_PROFILE] until the Profiles layer lands
/// (the same deferral [com.vortx.android.search.SearchHistoryStore] documents). When it does, inject the
/// active profile id and call [reload] on a switch, exactly like Apple's `reload()` off `Profiles`. Using
/// a per-profile key means one profile's pins can NEVER leak into another (the no-cross-profile-leak
/// invariant), the moment the id provider returns real ids.
class SourcePinStore(
    context: Context,
    private val activeProfileId: () -> String = { DEFAULT_PROFILE },
) {
    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private var loadedProfile: String? = null
    private var entryPins: MutableMap<String, SourcePin> = mutableMapOf() // metaId -> pin
    private var globalPin: SourcePin? = null

    init { reload() }

    /// Re-read the active profile's pins. Called once at init and on every profile switch. Mirrors Apple
    /// `SourcePinStore.reload`: a missing / corrupt blob resets to empty rather than throwing.
    fun reload() {
        val profile = activeProfileId()
        loadedProfile = profile
        val raw = prefs.getString(key(profile), null)
        if (raw == null) {
            entryPins = mutableMapOf(); globalPin = null; return
        }
        val decoded = runCatching { decodeBlob(JSONObject(raw)) }.getOrNull()
        if (decoded == null) {
            entryPins = mutableMapOf(); globalPin = null
        } else {
            entryPins = decoded.first.toMutableMap(); globalPin = decoded.second
        }
    }

    private fun persist() {
        val profile = loadedProfile ?: activeProfileId()
        prefs.edit().putString(key(profile), encodeBlob(entryPins, globalPin).toString()).apply()
        StreamRanking.invalidateCaches() // a pin changes rank order; memoized scores must be dropped
    }

    // ---- Mutations ----

    fun pin(stream: StreamSource, addon: String, scope: SourcePinScope, context: SourcePinContext) {
        val p = makePin(addon, stream)
        when (scope) {
            SourcePinScope.ENTRY -> entryPins[context.metaId] = p
            SourcePinScope.GLOBAL -> globalPin = p
        }
        persist()
    }

    fun unpin(scope: SourcePinScope, context: SourcePinContext) {
        when (scope) {
            SourcePinScope.ENTRY -> entryPins.remove(context.metaId)
            SourcePinScope.GLOBAL -> globalPin = null
        }
        persist()
    }

    fun clearAll() {
        if (entryPins.isEmpty() && globalPin == null) return
        entryPins = mutableMapOf(); globalPin = null; persist()
    }

    val pinnedCount: Int get() = entryPins.size + (if (globalPin == null) 0 else 1)

    // ---- Resolution + matching ----

    /// The pin that applies to a title, most-specific first: an [SourcePinScope.ENTRY] pin for this meta id
    /// wins over the [SourcePinScope.GLOBAL] one. Null when nothing is pinned for this context. Mirrors
    /// Apple `effectivePin`.
    fun effectivePin(context: SourcePinContext?): ResolvedPin? {
        if (context != null) entryPins[context.metaId]?.let { return ResolvedPin(it, SourcePinScope.ENTRY) }
        globalPin?.let { return ResolvedPin(it, SourcePinScope.GLOBAL) }
        return null
    }

    fun entryPin(context: SourcePinContext): SourcePin? = entryPins[context.metaId]

    companion object {
        const val PREFS_FILE = "vortx_settings"
        const val DEFAULT_PROFILE = "default"

        private fun key(profile: String): String = "stremiox.sourcePins.$profile"

        /// Build a pin from a chosen stream, capturing its signature (Apple `makePin`).
        fun makePin(addon: String, stream: StreamSource): SourcePin = SourcePin(
            addon = addon,
            quality = StreamRanking.qualityLabel(stream),
            flavor = StreamRanking.releaseFlavor(stream),
            bingeGroup = stream.bingeGroup,
        )

        /// Whether [stream] (from [addon]) matches a resolved pin. Used by both the ranker bonus
        /// ([StreamRanking.pinBonus]) and the row badge, so the badge marks exactly the streams the pin
        /// would float to the top. Mirrors Apple `SourcePinStore.matches`.
        fun matches(stream: StreamSource, addon: String, pin: ResolvedPin): Boolean {
            val addonEqual = addon.equals(pin.pin.addon, ignoreCase = true)
            return when (pin.scope) {
                SourcePinScope.GLOBAL -> addonEqual
                SourcePinScope.ENTRY -> {
                    val bg = pin.pin.bingeGroup
                    if (!bg.isNullOrEmpty() && stream.bingeGroup == bg) {
                        true
                    } else {
                        addonEqual && StreamRanking.qualityLabel(stream) == pin.pin.quality
                    }
                }
            }
        }

        // ---- JSON blob (hand-rolled with org.json; no kotlinx.serialization) ----
        // Shape mirrors Apple's Codable `Blob { entry: [String: SourcePin], global: SourcePin? }`.

        private fun encodeBlob(entry: Map<String, SourcePin>, global: SourcePin?): JSONObject {
            val obj = JSONObject()
            val entryObj = JSONObject()
            for ((metaId, pin) in entry) entryObj.put(metaId, pinToJson(pin))
            obj.put("entry", entryObj)
            if (global != null) obj.put("global", pinToJson(global))
            return obj
        }

        private fun decodeBlob(obj: JSONObject): Pair<Map<String, SourcePin>, SourcePin?> {
            val entry = mutableMapOf<String, SourcePin>()
            obj.optJSONObject("entry")?.let { entryObj ->
                val keys = entryObj.keys()
                while (keys.hasNext()) {
                    val metaId = keys.next()
                    entryObj.optJSONObject(metaId)?.let { entry[metaId] = pinFromJson(it) }
                }
            }
            val global = obj.optJSONObject("global")?.let { pinFromJson(it) }
            return entry to global
        }

        private fun pinToJson(p: SourcePin): JSONObject = JSONObject().apply {
            put("addon", p.addon)
            put("quality", p.quality)
            put("flavor", p.flavor)
            p.bingeGroup?.let { put("bingeGroup", it) }
        }

        private fun pinFromJson(o: JSONObject): SourcePin = SourcePin(
            addon = o.optString("addon", ""),
            quality = o.optString("quality", ""),
            flavor = o.optString("flavor", ""),
            bingeGroup = if (o.has("bingeGroup") && !o.isNull("bingeGroup")) o.getString("bingeGroup") else null,
        )
    }
}
