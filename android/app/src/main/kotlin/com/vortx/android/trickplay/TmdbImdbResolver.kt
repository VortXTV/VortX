package com.vortx.android.trickplay

import android.content.Context
import android.content.SharedPreferences
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Resolve a `tmdb:…` library id (the identity our hub / TMDB catalogs key plays with) to its `tt…` IMDb
 * id. Android port of the "TMDB-keyed plays -> IMDb identity" slice of Apple
 * `app/SourcesShared/CommunityTrickplay.swift` (the `resolveIMDbID` / `fetchExternalIMDbID` / `ttPrefix`
 * / `cachedIMDbID` block), lifted into its OWN reusable helper because more than trickplay needs it: the
 * SAME resolve unblocks tmdb-catalog SCROBBLES (Trakt / SIMKL) and community-trickplay contribution for
 * plays launched from our own TMDB-backed catalogs, which otherwise carry a `tmdb:NNN` id that every
 * `tt`-guarded consumer silently drops.
 *
 * Resolution runs against VortX's KEYLESS catalog edge (`catalogs.vortx.tv/3/{movie|tv}/{id}/external_ids`,
 * edge-signed, TMDB key injected server-side), the SAME edge + signing contract [com.vortx.android.person.
 * TMDBPersonClient] uses. Apple additionally falls back to a direct-TMDB call when the user set their own
 * key; Android has no per-user TMDB key surface (see TMDBPersonClient's doc), so this is edge-only, exactly
 * as that client is.
 *
 * PERSISTENCE (mirrors Apple's `tmdb2ttCache` + `UserDefaults` map): a resolved (rawId -> tt) pair is
 * cached in memory AND written to `SharedPreferences`, so a title resolves over the network at most ONCE
 * per install. The in-memory map is hydrated from disk lazily on first [resolveImdbId] and is process-wide
 * (this is an `object`), matching the Apple static cache. All map access is guarded by [lock] because
 * reads ([cachedImdbId]) and writes ([resolveImdbId]) can race across coroutines/threads, the same reason
 * Apple wraps every access in `tmdb2ttLock`.
 *
 * FAIL-SOFT by contract, exactly like the Swift original: returns null on an unparseable id, both media
 * lookups missing, a non-200, or any transport error. Never throws.
 */
object TmdbImdbResolver {

    /**
     * The keyless catalog edge base, path-compatible with TMDB's `/3` namespace. This is the baked default
     * Apple's `RemoteConfig.catalogsEndpoint` ships (`endpointCatalogs`); Android has no remote-config dial
     * yet, so the shipping value is used directly, identical to [com.vortx.android.person.TMDBPersonClient].
     * `catalogs.vortx.tv` is one of [VortXEdgeAuth]'s gated hosts, so [sign] stamps every request here.
     */
    private const val EDGE_BASE = "https://catalogs.vortx.tv/3"

    private const val TIMEOUT_MS = 10_000

    /** Prefs file + key for the persisted tmdb->tt map (Apple's `stremiox.trickplay.tmdb2tt` UserDefaults key). */
    private const val PREFS_FILE = "vortx_trickplay_tmdb2tt"
    private const val KEY_MAP = "map"

    private val lock = Any()
    private val cache = HashMap<String, String>()

    @Volatile private var prefs: SharedPreferences? = null
    @Volatile private var hydrated = false

    /**
     * The leading `tt…` id inside a raw id string ("tt15239678", "tt14452776:1:2"), or null. Lets a meta's
     * `behaviorHints.defaultVideoId` (often "tt…:s:e" on series) seed the shareable identity for free, and
     * is how [fetchExternalImdbId] normalizes TMDB's `imdb_id`. Mirrors Apple `CommunityTrickplay.ttPrefix`.
     */
    fun ttPrefix(raw: String?): String? {
        val r = raw ?: return null
        return TT_PREFIX_REGEX.find(r)?.value
    }

    /**
     * Synchronous cache lookup: the tt id previously resolved for a raw `tmdb:…` library id, or null.
     * Reads the process-wide in-memory map only (populated by [resolveImdbId], hydrated from disk on the
     * first resolve of the process). Mirrors Apple `CommunityTrickplay.cachedIMDbID(for:)`.
     */
    fun cachedImdbId(rawId: String): String? {
        val key = rawId.lowercase()
        synchronized(lock) { return cache[key] }
    }

    /**
     * Resolve a `tmdb:…` library id to its `tt…` IMDb id so those plays contribute + fetch community
     * trickplay (and scrobble) exactly like Cinemeta (`tt…`) plays. Tries the hinted media type first, then
     * the other (a bare "tmdb:NNN" does not say movie-vs-tv). Cached persistently; fail-soft null on an
     * unparseable id / both lookups missing. Mirrors Apple `CommunityTrickplay.resolveIMDbID`.
     *
     * Accepts the canonical "tmdb:693134" and tolerates "tmdb:movie:693134" / "tmdb:tv:693134".
     */
    suspend fun resolveImdbId(context: Context, rawId: String, seriesHint: Boolean): String? {
        ensureHydrated(context)
        val cacheKey = rawId.lowercase()
        synchronized(lock) { cache[cacheKey] }?.let { return it }

        val parts = cacheKey.split(":").filter { it.isNotEmpty() }
        if (parts.firstOrNull() != "tmdb") return null
        val numeric = parts.drop(1).firstOrNull { it.toIntOrNull() != null } ?: return null
        val explicit = when {
            parts.contains("tv") -> "tv"
            parts.contains("movie") -> "movie"
            else -> null
        }
        val order = explicit?.let { listOf(it) }
            ?: if (seriesHint) listOf("tv", "movie") else listOf("movie", "tv")

        for (media in order) {
            val tt = fetchExternalImdbId(media = media, tmdbId = numeric) ?: continue
            val snapshot = synchronized(lock) {
                cache[cacheKey] = tt
                HashMap(cache)
            }
            persist(context, snapshot)
            return tt
        }
        return null
    }

    /**
     * One `external_ids` lookup off the keyless edge, signed via [VortXEdgeAuth] (stamped after the method
     * + URL are set, before the connection opens, per the signer's contract). Runs on [Dispatchers.IO]; a
     * non-200 or any transport error resolves to null. Mirrors the edge half of Apple `fetchExternalIMDbID`.
     */
    private suspend fun fetchExternalImdbId(media: String, tmdbId: String): String? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL("$EDGE_BASE/$media/$tmdbId/external_ids")
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                setRequestProperty("accept", "application/json")
            }
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            val obj = runCatching { JSONObject(text) }.getOrNull() ?: return@withContext null
            ttPrefix(obj.optStringOrNull("imdb_id"))
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    /** Lazily load the persisted map into the in-memory cache once per process (thread-safe). */
    private fun ensureHydrated(context: Context) {
        if (hydrated) return
        synchronized(lock) {
            if (hydrated) return
            val store = prefs(context)
            val raw = store.getString(KEY_MAP, null)
            if (raw != null) {
                runCatching { JSONObject(raw) }.getOrNull()?.let { obj ->
                    val keys = obj.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        val v = obj.optString(k, "")
                        if (v.isNotEmpty()) cache.putIfAbsent(k, v)
                    }
                }
            }
            hydrated = true
        }
    }

    /** Write the (snapshot of the) whole map back to disk, issued outside [lock] with a taken snapshot. */
    private fun persist(context: Context, snapshot: Map<String, String>) {
        val obj = JSONObject()
        for ((k, v) in snapshot) obj.put(k, v)
        prefs(context).edit().putString(KEY_MAP, obj.toString()).apply()
    }

    private fun prefs(context: Context): SharedPreferences {
        prefs?.let { return it }
        val store = context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)
        prefs = store
        return store
    }

    /** Like `optString` but null (not "") for a missing or JSON-null value, matching the repo's helpers. */
    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    /** Leading `tt` + at least 6 digits, anchored at the start (Apple `^tt\d{6,}`). */
    private val TT_PREFIX_REGEX = Regex("^tt\\d{6,}")
}
