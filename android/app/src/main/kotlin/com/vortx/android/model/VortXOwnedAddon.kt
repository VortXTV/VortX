package com.vortx.android.model

import org.json.JSONObject

/**
 * Account-owns-addons hydration descriptor: the shape needed to re-hydrate the engine's add-on set
 * network-free when a Stremio session is absent/degraded (the "0 sources / 0 add-ons" fix). The Android port
 * of Apple `VortXOwnedAddon` (in `CoreModels.swift`).
 *
 * The shape mirrors the engine's `InstallAddon` descriptor (`{transportUrl, manifest, flags}`) so a
 * re-dispatch is byte-shape-exact, plus [name] for the dashboard. [manifest] / [flags] are kept as opaque
 * `JSONObject` passthrough (the Kotlin analogue of Apple's `[String: Any]`) so the descriptor round-trips into
 * the engine unchanged without modeling the whole Stremio manifest schema.
 *
 * Not a `data class`: `JSONObject` has reference identity semantics, so structural equality would be
 * misleading for this opaque passthrough.
 */
class VortXOwnedAddon private constructor(
    val transportUrl: String,
    val name: String,
    /** Opaque passthrough, re-dispatched verbatim to the engine. */
    val manifest: JSONObject,
    val flags: JSONObject?,
) {
    /**
     * The exact `InstallAddon` descriptor the engine expects. Keys are camelCase to match the engine's serde
     * contract (a lowercase-key mismatch silently no-ops in the engine). Mirrors Apple `installDescriptor`.
     */
    val installDescriptor: JSONObject
        get() = JSONObject().apply {
            put("transportUrl", transportUrl)
            put("manifest", manifest)
            put("flags", flags ?: JSONObject().put("official", false).put("protected", false))
        }

    companion object {
        /**
         * Build from one `doc.vortx.addons` (or `doc.addons`) entry. Tolerates the legacy `{transportUrl,name}`
         * shape (manifest absent) by returning null: without a manifest the engine cannot InstallAddon, so the
         * entry is dropped rather than dispatched as a no-op. Mirrors Apple `init?(json:)`.
         */
        fun fromJson(json: JSONObject): VortXOwnedAddon? {
            val url = json.optString("transportUrl").takeIf { it.isNotEmpty() } ?: return null
            val manifest = json.optJSONObject("manifest") ?: return null
            val flags = json.optJSONObject("flags")
            val name = json.optString("name").takeIf { it.isNotEmpty() }
                ?: manifest.optString("name").takeIf { it.isNotEmpty() }
                ?: url
            return VortXOwnedAddon(url, name, manifest, flags)
        }
    }
}
