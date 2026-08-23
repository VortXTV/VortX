package com.vortx.android.communityjs

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.vortx.android.config.RemoteConfig
import com.vortx.android.config.RemoteConfigDefaults
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONArray
import org.json.JSONObject

/**
 * The installed state for user-supplied community JavaScript providers.
 *
 * This store intentionally persists no app credential and ships no provider list. Provider source is
 * encrypted at rest because it is executable input, while manifest URLs and enablement state are held in
 * the same encrypted record. A failure to open the keystore fails closed: no provider is considered enabled.
 */
class CommunityJsProviderStore(context: Context) {
    data class Provider(
        val id: String,
        val name: String,
        val supportedTypes: Set<String>,
        val code: String,
        val enabled: Boolean,
    ) {
        fun supports(mediaType: String): Boolean = mediaType.lowercase() in supportedTypes
    }

    data class InstallResult(val installed: Int, val message: String, val failed: Boolean)

    private val appContext = context.applicationContext
    private val prefs by lazy {
        val key = MasterKey.Builder(appContext).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
        EncryptedSharedPreferences.create(
            appContext,
            PREFS_FILE,
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** Both the remote kill switch and an explicit device choice must be true. Defaults are false. */
    val featureEnabled: Boolean
        get() = userEnabled && RemoteConfig.isFeatureOn(FEATURE_KEY, RemoteConfigDefaults.FEATURE_COMMUNITY_JS_PLUGINS)

    var userEnabled: Boolean
        get() = runCatching { prefs.getBoolean(KEY_ENABLED, false) }.getOrDefault(false)
        set(value) { runCatching { prefs.edit().putBoolean(KEY_ENABLED, value).apply() } }

    val manifestUrl: String
        get() = runCatching { prefs.getString(KEY_MANIFEST, "").orEmpty() }.getOrDefault("")

    fun providers(): List<Provider> = if (!featureEnabled) emptyList() else decodeProviders()

    fun installedProviders(): List<Provider> = decodeProviders()

    suspend fun install(rawUrl: String): InstallResult = withContext(Dispatchers.IO) {
        val manifestUrl = CommunityJsUrlPolicy.manifestUrl(rawUrl)
            ?: return@withContext InstallResult(0, "Enter an HTTPS manifest URL.", failed = true)
        val manifestText = fetchText(manifestUrl)
            ?: return@withContext InstallResult(0, "Could not fetch the manifest.", failed = true)
        val root = runCatching { JSONObject(manifestText) }.getOrNull()
            ?: return@withContext InstallResult(0, "The manifest is not valid JSON.", failed = true)
        val entries = root.optJSONArray("scrapers") ?: JSONArray()
        val installed = ArrayList<Provider>()
        var totalSourceBytes = 0
        for (index in 0 until minOf(entries.length(), MAX_PROVIDER_COUNT)) {
            val entry = entries.optJSONObject(index) ?: continue
            if (entry.has("enabled") && !entry.optBoolean("enabled", true)) continue
            val id = entry.optString("id").trim()
            val file = entry.optString("filename").trim()
            if (!VALID_ID.matches(id) || file.isEmpty()) continue
            val providerUrl = CommunityJsUrlPolicy.providerUrl(manifestUrl, file) ?: continue
            val code = fetchText(providerUrl)?.takeIf { it.isNotBlank() && it.toByteArray().size <= MAX_SOURCE_BYTES } ?: continue
            totalSourceBytes += code.toByteArray(Charsets.UTF_8).size
            if (totalSourceBytes > MAX_TOTAL_SOURCE_BYTES) break
            val types = entry.optJSONArray("supportedTypes")
                ?.let { array -> buildSet { for (i in 0 until array.length()) add(array.optString(i).lowercase()) } }
                ?.intersect(SUPPORTED_MEDIA_TYPES)
                ?.ifEmpty { SUPPORTED_MEDIA_TYPES }
                ?: SUPPORTED_MEDIA_TYPES
            installed += Provider(
                id = id,
                name = entry.optString("name").trim().ifEmpty { id },
                supportedTypes = types,
                code = code,
                enabled = true,
            )
        }
        if (installed.isEmpty()) return@withContext InstallResult(0, "No usable providers were found.", failed = true)
        runCatching {
            prefs.edit()
                .putString(KEY_MANIFEST, manifestUrl)
                .putString(KEY_PROVIDERS, encodeProviders(installed))
                .apply()
        }.fold(
            onSuccess = { InstallResult(installed.size, "Installed ${installed.size} community provider(s).", failed = false) },
            onFailure = { InstallResult(0, "Secure storage is unavailable.", failed = true) },
        )
    }

    suspend fun refresh(): InstallResult = install(manifestUrl)

    fun setProviderEnabled(id: String, enabled: Boolean) {
        val updated = decodeProviders().map { provider -> if (provider.id == id) provider.copy(enabled = enabled) else provider }
        runCatching { prefs.edit().putString(KEY_PROVIDERS, encodeProviders(updated)).apply() }
    }

    fun clear() {
        runCatching { prefs.edit().remove(KEY_MANIFEST).remove(KEY_PROVIDERS).apply() }
    }

    private fun decodeProviders(): List<Provider> = runCatching {
        val array = JSONArray(prefs.getString(KEY_PROVIDERS, "[]"))
        buildList {
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                val id = item.optString("id").trim()
                val code = item.optString("code")
                if (!VALID_ID.matches(id) || code.isBlank() || code.toByteArray().size > MAX_SOURCE_BYTES) continue
                val types = item.optJSONArray("types")?.let { typesArray ->
                    buildSet { for (j in 0 until typesArray.length()) add(typesArray.optString(j).lowercase()) }
                }?.intersect(SUPPORTED_MEDIA_TYPES)?.ifEmpty { SUPPORTED_MEDIA_TYPES } ?: SUPPORTED_MEDIA_TYPES
                add(Provider(id, item.optString("name").ifBlank { id }, types, code, item.optBoolean("enabled", true)))
            }
        }
    }.getOrDefault(emptyList())

    private fun encodeProviders(providers: List<Provider>): String = JSONArray().apply {
        providers.forEach { provider ->
            put(JSONObject().apply {
                put("id", provider.id)
                put("name", provider.name)
                put("types", JSONArray(provider.supportedTypes.toList()))
                put("code", provider.code)
                put("enabled", provider.enabled)
            })
        }
    }.toString()

    private fun fetchText(url: String): String? = CommunityJsPublicHttp.fetch(
        rawUrl = url,
        requireHttps = true,
        headers = mapOf("User-Agent" to USER_AGENT),
        timeoutMs = REQUEST_TIMEOUT_MS,
        maxBytes = MAX_SOURCE_BYTES,
    )?.takeIf { it.status in 200..299 }?.body

    companion object {
        const val FEATURE_KEY = "communityJSPlugins"
        private const val PREFS_FILE = "community_js_providers"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_MANIFEST = "manifest"
        private const val KEY_PROVIDERS = "providers"
        private const val MAX_SOURCE_BYTES = 1_000_000
        private const val MAX_TOTAL_SOURCE_BYTES = 4_000_000
        private const val MAX_PROVIDER_COUNT = 12
        private const val REQUEST_TIMEOUT_MS = 25_000L
        private const val USER_AGENT = "Mozilla/5.0 (Android) AppleWebKit/537.36 Chrome/125 Safari/537.36"
        private val VALID_ID = Regex("[A-Za-z0-9._-]{1,96}")
        private val SUPPORTED_MEDIA_TYPES = setOf("movie", "tv")
    }
}

/** Native URL policy. It is enforced before every manifest/provider and provider-originated request. */
object CommunityJsUrlPolicy {
    fun manifestUrl(raw: String): String? {
        val trimmed = raw.trim()
        val candidate = if (trimmed.endsWith("manifest.json", ignoreCase = true)) trimmed else "$trimmed/manifest.json"
        return candidate.takeIf(::isPublicHttpsUrl)
    }

    fun providerUrl(manifestUrl: String, filename: String): String? = runCatching {
        val absolute = manifestUrl.toHttpUrlOrNull()?.resolve(filename)?.toString() ?: return null
        absolute.takeIf(::isPublicHttpsUrl)
    }.getOrNull()

    fun isPublicHttpsUrl(raw: String): Boolean = runCatching {
        val url = raw.toHttpUrlOrNull() ?: return false
        url.isHttps && isPublicHost(url.host)
    }.getOrDefault(false)

    fun isPublicHttpUrl(raw: String): Boolean = runCatching {
        val url = raw.toHttpUrlOrNull() ?: return false
        (url.isHttps || url.scheme == "http") && isPublicHost(url.host)
    }.getOrDefault(false)

    private fun isPublicHost(host: String): Boolean {
        val normalized = host.lowercase()
        if (normalized == "localhost" || normalized.endsWith(".localhost") || normalized.endsWith(".local")) return false
        return runCatching {
            com.vortx.android.engine.PublicAddressPolicy.requireLiteralPublicOrHostname(normalized)
            true
        }.getOrDefault(false)
    }
}
