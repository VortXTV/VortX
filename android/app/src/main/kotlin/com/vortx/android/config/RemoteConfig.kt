package com.vortx.android.config

import android.content.Context
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Minimal Android port of Apple `RemoteConfig` (app/SourcesShared/RemoteConfig.swift), scoped to the ONE
 * dial this lane wires: the `features.collectionsHub` fleet kill-switch. The Apple file decodes a large
 * schema; this port keeps only the feature-flag map, which is all the collections hub reads.
 *
 * DESIGN CONTRACT (mirrors Apple, kept intentionally small):
 *   1. Every accessor has a HARDCODED baked default equal to the shipping value. A missing service, a null
 *      field, or a corrupt cache is behaviorally identical to today. [bakedFeatures] holds the defaults.
 *   2. Reads are SYNCHRONOUS and LOCK-FREE: [snapshot] is a `@Volatile` immutable [Snapshot] that is only
 *      ever REPLACED, never mutated, so a reader sees the old or the new fully-formed value, never torn
 *      state. It starts baked so a read before [bootstrap] is shipping-correct.
 *   3. FAIL-SOFT everywhere: any fetch / decode / disk error keeps the last-good snapshot (or baked). A
 *      remote `master.remoteConfigEnabled == false` discards the fetched config back to baked, matching the
 *      Apple kill-switch semantics.
 *   4. The config GET is SIGNED with the shared [VortXEdgeAuth] HMAC helper (config.vortx.tv is a gated
 *      host). With no secret provisioned the signature is a safe no-op the worker's observe mode allows, so
 *      an unprovisioned build fetches exactly the same way.
 */
object RemoteConfig {
    private const val CONFIG_URL = "https://config.vortx.tv/v1/config.json"
    private const val FETCH_TIMEOUT_MS = 8_000
    private const val PREFS_FILE = "vortx_remote_config"
    private const val CACHE_KEY = "vortx.remoteConfig.features"

    /** Baked feature defaults (== the shipping values). An absent remote feature falls back to its default. */
    private val bakedFeatures: Map<String, Boolean> = mapOf(
        "collectionsHub" to true,
    )

    @Volatile
    private var snapshot: Snapshot = Snapshot(bakedFeatures)

    /** Immutable, already-resolved feature snapshot. Read lock-free on any thread. */
    data class Snapshot(private val features: Map<String, Boolean>) {
        /** Remote true/false wins; an absent (null) remote feature falls back to the call site's default. */
        fun isFeatureOn(key: String, default: Boolean): Boolean = features[key] ?: default
    }

    /** The current snapshot (baked until [bootstrap] loads a cached / fetched config). */
    fun current(): Snapshot = snapshot

    /** Convenience: [Snapshot.isFeatureOn] against the current snapshot. */
    fun isFeatureOn(key: String, default: Boolean): Boolean = snapshot.isFeatureOn(key, default)

    /**
     * (1) Synchronously load the last-good cached features and build the snapshot (else all-baked).
     * (2) Kick a single background refresh on [scope]. Never throws; safe to call once at process start.
     */
    fun bootstrap(context: Context, scope: CoroutineScope) {
        val appContext = context.applicationContext
        loadCached(appContext)?.let { snapshot = Snapshot(mergedWithBaked(it)) }
        scope.launch { runCatching { refresh(appContext) } }
    }

    /**
     * GET the config, decode `features`, and swap the snapshot + cache the feature map. A remote
     * `master.remoteConfigEnabled == false` discards to baked (and is NOT cached, so removing the field
     * restores it). Any error keeps the last-good snapshot.
     */
    private suspend fun refresh(context: Context) = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(CONFIG_URL).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = FETCH_TIMEOUT_MS
                readTimeout = FETCH_TIMEOUT_MS
                useCaches = true
                setRequestProperty("accept", "application/json")
            }
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return@withContext
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val root = JSONObject(text)
            // master.remoteConfigEnabled == false is the whole-system kill switch: discard to baked and do
            // not persist, so deleting the field restores the last-good behavior on the next fetch.
            if (root.optJSONObject("master")?.let { it.has("remoteConfigEnabled") && !it.optBoolean("remoteConfigEnabled", true) } == true) {
                snapshot = Snapshot(bakedFeatures)
                clearCache(context)
                return@withContext
            }
            val features = parseFeatures(root.optJSONObject("features")) ?: return@withContext
            snapshot = Snapshot(mergedWithBaked(features))
            cache(context, features)
        } catch (_: Exception) {
            // Timeout / offline / decode failure: keep last-good. Never throw.
        } finally {
            connection?.disconnect()
        }
    }

    /** Only boolean feature entries are honored; everything else in the object is ignored. */
    private fun parseFeatures(features: JSONObject?): Map<String, Boolean>? {
        if (features == null) return null
        val out = HashMap<String, Boolean>()
        val keys = features.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            if (!features.isNull(key) && features.opt(key) is Boolean) {
                out[key] = features.optBoolean(key)
            }
        }
        return out
    }

    /** Baked defaults overlaid by any explicit remote value, so an absent feature keeps its shipping default. */
    private fun mergedWithBaked(remote: Map<String, Boolean>): Map<String, Boolean> = bakedFeatures + remote

    private fun cache(context: Context, features: Map<String, Boolean>) {
        val json = JSONObject().apply { features.forEach { (k, v) -> put(k, v) } }
        prefs(context).edit().putString(CACHE_KEY, json.toString()).apply()
    }

    private fun clearCache(context: Context) {
        prefs(context).edit().remove(CACHE_KEY).apply()
    }

    private fun loadCached(context: Context): Map<String, Boolean>? {
        val raw = prefs(context).getString(CACHE_KEY, null) ?: return null
        return runCatching { parseFeatures(JSONObject(raw)) }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
}
