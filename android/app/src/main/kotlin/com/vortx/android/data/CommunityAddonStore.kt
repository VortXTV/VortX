package com.vortx.android.data

import com.vortx.android.model.StoreAddon
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/// Loads the OFFICIAL Stremio community add-on collection (the same list the official clients show) so the
/// in-app store does not depend on scraping a third-party site. Kotlin port of Apple
/// `AddonStoreView.CommunityAddonStore`. Fetched once, cached in memory (owned by the store ViewModel),
/// and fails soft to an empty list (the store then just shows nothing rather than an error wall).
class CommunityAddonStore(
    private val client: OkHttpClient = defaultClient,
) {
    /// Fetch + parse the collection off the main thread. Returns an empty list on any network/parse error
    /// (fail-soft), so the caller distinguishes "loaded nothing" from "failed" only by whether it wanted a
    /// non-empty result. Never throws.
    suspend fun fetch(): List<StoreAddon> = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(COLLECTION_URL)
            // Some CDNs in front of the collection reject non-browser User-Agents (same lesson as the health
            // probe and the Apple store). Present a browser UA.
            .header("User-Agent", BROWSER_USER_AGENT)
            .get()
            .build()
        runCatching {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use emptyList<StoreAddon>()
                val body = response.body?.string() ?: return@use emptyList<StoreAddon>()
                parse(body)
            }
        }.getOrDefault(emptyList())
    }

    private fun parse(body: String): List<StoreAddon> {
        val array = runCatching { JSONArray(body) }.getOrNull() ?: return emptyList()
        val out = mutableListOf<StoreAddon>()
        for (i in 0 until array.length()) {
            val entry = array.optJSONObject(i) ?: continue
            val transportUrl = entry.optStringOrNull("transportUrl") ?: continue
            val manifest = entry.optJSONObject("manifest") ?: continue
            val name = manifest.optStringOrNull("name") ?: continue
            out += StoreAddon(
                transportUrl = transportUrl,
                name = name,
                summary = manifest.optStringOrNull("description").orEmpty(),
                logo = manifest.optStringOrNull("logo"),
                types = manifest.optStringList("types"),
            )
        }
        return out
    }

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (isNull(key)) null else optString(key).takeIf { it.isNotBlank() }

    private fun JSONObject.optStringList(key: String): List<String> {
        val array = optJSONArray(key) ?: return emptyList()
        val out = mutableListOf<String>()
        for (i in 0 until array.length()) {
            val value = array.optString(i)
            if (value.isNotBlank()) out += value
        }
        return out
    }

    companion object {
        /// The official, public community collection endpoint (same host the app already uses for auth).
        private const val COLLECTION_URL = "https://api.strem.io/addonscollection.json"
        private const val BROWSER_USER_AGENT =
            "Mozilla/5.0 (Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

        private val defaultClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(12, TimeUnit.SECONDS)
                .readTimeout(12, TimeUnit.SECONDS)
                .callTimeout(20, TimeUnit.SECONDS)
                .build()
        }
    }
}
