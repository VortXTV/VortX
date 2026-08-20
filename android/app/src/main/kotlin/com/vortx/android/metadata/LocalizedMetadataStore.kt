package com.vortx.android.metadata

import android.content.Context
import com.vortx.android.config.RemoteConfig
import com.vortx.android.net.VortXEdgeAuth
import com.vortx.android.ui.prefs.AppLanguage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.Locale

/**
 * Discover pack, part 1 (Android side): localized TITLE + POSTER + LOGO in the user's language across every
 * catalog, the Kotlin port of Apple `app/SourcesShared/LocalizedMetadata.swift`. The engine / add-ons send
 * whatever title + art they have (usually English); this store OVERRIDES the display values with a localized
 * entry looked up by imdb/tmdb id + the user's language from the shared VortX pool worker
 * (catalogs.vortx.tv /meta/l10n), self-seeded from users who have their own TMDB key.
 *
 * Fallback chain (server + client agree): user-language localized -> textless/international art -> original
 * (whatever the add-on sent). NEVER blank: a miss returns null and the view keeps the add-on value.
 *
 * Gating: off unless the resolved app language is non-English (English needs no override) AND the fleet flag
 * `features.localizedMetadata` is on (baked true). English users and a remote `false` get today's behavior
 * and the subsystem never touches the network.
 *
 * Lookups are BATCHED (a hub screen's worth per request, capped by the worker at 60) and cached both in
 * memory (the observable [entries] map) and on disk (a title + two short paths is tiny + near-immutable). A
 * publish of the resolved map re-renders any observing view.
 */
object LocalizedMetadataStore {

    /** A pooled localized entry for one title (any field may be empty). Apple `LocalizedMeta`. */
    data class LocalizedMeta(val title: String, val posterPath: String, val logoPath: String) {
        val localizedTitle: String? get() = title.ifEmpty { null }
        val posterURL: String? get() = posterPath.ifEmpty { null }?.let { "https://image.tmdb.org/t/p/w342$it" }
        val logoURL: String? get() = logoPath.ifEmpty { null }?.let { "https://image.tmdb.org/t/p/w500$it" }
        val isEmpty: Boolean get() = title.isEmpty() && posterPath.isEmpty() && logoPath.isEmpty()
    }

    private const val POOL_DEFAULT_BASE = "https://catalogs.vortx.tv"
    private const val MAX_IDS_PER_READ = 60
    private const val MAX_BACKFILL_PER_FLUSH = 8
    private const val DISK_CACHE_CAP = 4000
    private const val DEBOUNCE_MS = 120L
    private const val TIMEOUT_MS = 12_000

    @Volatile private var appContext: Context? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Resolved entries keyed by "<lang>|<id>" (a stored all-empty entry marks a remembered miss). */
    private val _entries = MutableStateFlow<Map<String, LocalizedMeta>>(emptyMap())
    val entries: StateFlow<Map<String, LocalizedMeta>> = _entries.asStateFlow()

    private val lock = Mutex()
    private val inFlight = HashSet<String>()
    private val pending = LinkedHashSet<String>()
    private var flushJob: Job? = null

    /** Wire the process application context once and hydrate the disk cache. Idempotent. */
    fun init(context: Context) {
        appContext = context.applicationContext
        scope.launch { loadDiskCache() }
    }

    /** Off for English + when the fleet flag is off. Apple `isEnabled`. */
    val isEnabled: Boolean
        get() = !LocalizedMetadataLanguage.isEnglish(appContext) &&
            RemoteConfig.isFeatureOn("localizedMetadata", true)

    // MARK: reads (view-facing)

    /** The localized title for an id, or null to keep the add-on's own title. Also enqueues a resolve. */
    fun title(id: String): String? = read(id) { it.localizedTitle }

    /** The localized poster URL for an id, or null to keep the add-on's own poster. */
    fun poster(id: String): String? = read(id) { it.posterURL }

    /** The localized logo URL for an id, or null to keep the add-on's own logo. */
    fun logo(id: String): String? = read(id) { it.logoURL }

    private inline fun read(id: String, project: (LocalizedMeta) -> String?): String? {
        if (!isEnabled || !isResolvableID(id)) return null
        request(id)
        return _entries.value[scopedKey(id)]?.let(project)
    }

    /** Enqueue a batch of ids for resolution (call when a rail / grid / hub page appears). Apple `resolve`. */
    fun resolve(ids: List<String>) {
        if (!isEnabled) return
        for (id in ids) if (isResolvableID(id)) request(id)
    }

    // MARK: batching

    private fun request(id: String) {
        val key = scopedKey(id)
        if (_entries.value.containsKey(key)) return
        scope.launch {
            val schedule = lock.withLock {
                if (_entries.value.containsKey(key) || inFlight.contains(key)) return@withLock false
                pending.add(id)
                if (flushJob == null) {
                    flushJob = scope.launch { debouncedFlush() }
                }
                true
            }
            if (!schedule) return@launch
        }
    }

    private suspend fun debouncedFlush() {
        delay(DEBOUNCE_MS)
        flush()
    }

    private suspend fun flush() {
        lock.withLock { flushJob = null }
        if (!isEnabled) {
            lock.withLock { pending.clear() }
            return
        }
        val lang = LocalizedMetadataLanguage.current(appContext)
        val batch = lock.withLock {
            val take = pending.take(MAX_IDS_PER_READ)
            pending.removeAll(take.toSet())
            for (id in take) inFlight.add(scopedKey(id, lang))
            take
        }
        if (batch.isEmpty()) return

        val fetched = fetchPool(batch, lang)
        val updates = HashMap<String, LocalizedMeta>()
        val misses = ArrayList<String>()
        for (id in batch) {
            val key = scopedKey(id, lang)
            val hit = fetched[id]
            if (hit != null && !hit.isEmpty) {
                updates[key] = hit
            } else {
                misses.add(id)
                // Record a negative so a miss is not re-fetched every layout (a user-key backfill can overwrite it).
                updates[key] = LocalizedMeta("", "", "")
            }
        }
        lock.withLock {
            for (id in batch) inFlight.remove(scopedKey(id, lang))
            if (updates.isNotEmpty()) {
                // ONE mutation of the observable map, not one per id, so a 60-id flush re-renders once.
                _entries.value = _entries.value + updates
            }
        }
        if (updates.isNotEmpty()) saveDiskCache()

        // Keep draining if there is still a backlog.
        val hasBacklog = lock.withLock {
            if (pending.isNotEmpty() && flushJob == null) {
                flushJob = scope.launch { flush() }
                true
            } else {
                false
            }
        }
        if (hasBacklog) return

        // For real misses, backfill from the user's own TMDB key (if any) and contribute back to seed the pool.
        if (misses.isNotEmpty() && ArtworkPreferences.tmdbKey() != null) {
            backfillFromUserKey(misses, lang)
        }
    }

    // MARK: pool read

    /** GET /meta/l10n?ids=<csv>&lang=<code> against the catalogs edge, signed via [VortXEdgeAuth]. */
    private suspend fun fetchPool(ids: List<String>, lang: String): Map<String, LocalizedMeta> {
        val base = poolBase() ?: return emptyMap()
        val url = "$base/meta/l10n?ids=${enc(ids.joinToString(","))}&lang=${enc(lang)}"
        val obj = getSigned(url) ?: return emptyMap()
        val items = obj.optJSONObject("items") ?: return emptyMap()
        val out = HashMap<String, LocalizedMeta>()
        items.keys().forEach { id ->
            val row = items.optJSONObject(id) ?: return@forEach   // null = miss; skip
            out[id] = LocalizedMeta(
                title = row.optString("title", ""),
                posterPath = row.optString("posterPath", ""),
                logoPath = row.optString("logoPath", ""),
            )
        }
        return out
    }

    // MARK: user-key backfill + contribute (self-seed the pool)

    private suspend fun backfillFromUserKey(ids: List<String>, lang: String) {
        val capped = ids.take(MAX_BACKFILL_PER_FLUSH)
        val results = withContext(Dispatchers.IO) {
            capped.map { id -> async { id to tmdbLocalized(id, lang) } }.awaitAll()
        }
        val backfilled = HashMap<String, LocalizedMeta>()
        val contributions = JSONArray()
        for ((id, meta) in results) {
            if (meta == null || meta.isEmpty) continue
            backfilled[scopedKey(id, lang)] = meta
            contributions.put(
                JSONObject()
                    .put("id", id).put("title", meta.title)
                    .put("posterPath", meta.posterPath).put("logoPath", meta.logoPath),
            )
        }
        if (backfilled.isNotEmpty()) {
            lock.withLock { _entries.value = _entries.value + backfilled }
            saveDiskCache()
        }
        if (contributions.length() > 0) contribute(contributions, lang)
    }

    /** Localized title + language-matched poster + logo for one id from TMDB with the user's key. */
    private suspend fun tmdbLocalized(id: String, lang: String): LocalizedMeta? {
        val key = ArtworkPreferences.tmdbKey() ?: return null
        val base = LocalizedMetadataLanguage.baseCode(appContext)
        val ref = tmdbRef(id, key) ?: return null
        val tmdbLang = tmdbLangForm(lang)
        // SECURITY: this URL carries the user's TMDB key as api_key=. Never logged verbatim.
        val url = "https://api.themoviedb.org/3/${ref.first}/${ref.second}" +
            "?api_key=${enc(key)}&language=${enc(tmdbLang)}" +
            "&append_to_response=images&include_image_language=${enc("$base,null,en")}"
        val obj = getJSON(url) ?: return null
        val title = if (ref.first == "tv") {
            obj.optString("name").ifEmpty { obj.optString("original_name") }
        } else {
            obj.optString("title").ifEmpty { obj.optString("original_title") }
        }
        val images = obj.optJSONObject("images")
        val poster = pickImagePath(images?.optJSONArray("posters"), base)
        val logo = pickImagePath(images?.optJSONArray("logos"), base)
        val meta = LocalizedMeta(title, poster, logo)
        return if (meta.isEmpty) null else meta
    }

    /** Resolve an app id (`tt...` / `tmdb:movie:123`) to a TMDB (kind, numeric id) with the user's key. */
    private suspend fun tmdbRef(id: String, key: String): Pair<String, String>? {
        if (id.startsWith("tmdb:")) {
            val parts = id.split(":")
            if (parts.size == 3) parts[2].toIntOrNull()?.let { return parts[1] to it.toString() }
            return null
        }
        if (!id.startsWith("tt")) return null
        val obj = getJSON("https://api.themoviedb.org/3/find/$id?external_source=imdb_id&api_key=${enc(key)}")
            ?: return null
        obj.optJSONArray("movie_results")?.optJSONObject(0)?.let {
            if (it.has("id")) return "movie" to it.optInt("id").toString()
        }
        obj.optJSONArray("tv_results")?.optJSONObject(0)?.let {
            if (it.has("id")) return "tv" to it.optInt("id").toString()
        }
        return null
    }

    /** POST /meta/l10n batch contribute (body-signed). Fail-soft: a failed contribute never surfaces. */
    private suspend fun contribute(items: JSONArray, lang: String) {
        val base = poolBase() ?: return
        val url = "$base/meta/l10n"
        val body = JSONObject().put("lang", lang).put("items", items).toString().toByteArray(Charsets.UTF_8)
        postSigned(url, body)
    }

    // MARK: HTTP

    private suspend fun getSigned(urlString: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false   // the pool edge caches; we cache on disk ourselves
            }
            VortXEdgeAuth.sign(connection)
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private suspend fun postSigned(urlString: String, body: ByteArray) = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            val url = URL(urlString)
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                doOutput = true
                useCaches = false
                setRequestProperty("Content-Type", "application/json")
            }
            // Body-bound signing (Apple `signIncludingBody`): stamp X-VX-Ts/Kid/Body/Sig for the gated host.
            VortXEdgeAuth.signingHeadersIncludingBody("POST", url, body)?.let { h ->
                connection.setRequestProperty(VortXEdgeAuth.tsHeaderName(), h.ts)
                connection.setRequestProperty(VortXEdgeAuth.kidHeaderName(), h.kid)
                connection.setRequestProperty(VortXEdgeAuth.bodyHeaderName(), h.bodyHash)
                connection.setRequestProperty(VortXEdgeAuth.sigHeaderName(), h.sig)
            }
            connection.outputStream.use { it.write(body) }
            connection.responseCode   // drain; result is ignored (fail-soft)
        } catch (_: IOException) {
            // fail-soft: the local entry already applied; the pool just isn't seeded from this client
        } finally {
            connection?.disconnect()
        }
        Unit
    }

    private suspend fun getJSON(urlString: String): JSONObject? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
            }
            if (connection.responseCode != 200) return@withContext null
            val text = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            runCatching { JSONObject(text) }.getOrNull()
        } catch (_: IOException) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    // MARK: helpers

    /** The pool base: the catalogs edge WITHOUT the trailing `/3` TMDB namespace (l10n lives at /meta/l10n). */
    private fun poolBase(): String = POOL_DEFAULT_BASE

    private fun isResolvableID(id: String): Boolean =
        id.startsWith("tt") || id.startsWith("tmdb:movie:") || id.startsWith("tmdb:tv:")

    private fun scopedKey(id: String): String = scopedKey(id, LocalizedMetadataLanguage.current(appContext))
    private fun scopedKey(id: String, lang: String): String = "$lang|$id"

    private fun enc(value: String): String =
        runCatching { URLEncoder.encode(value, "UTF-8").replace("+", "%20") }.getOrDefault(value)

    /** Map an app language code to TMDB's `language=` form. Apple `tmdbLangForm`. */
    private fun tmdbLangForm(code: String): String = when (code) {
        "zh-Hans" -> "zh-CN"
        "zh-Hant" -> "zh-TW"
        "pt-BR" -> "pt-BR"
        "pt-PT" -> "pt-PT"
        "fil" -> "tl"
        "nb" -> "no"
        else -> {
            val dash = code.indexOf('-')
            if (dash < 0) {
                code
            } else {
                val sub = code.substring(dash + 1)
                val baseStr = code.substring(0, dash).lowercase(Locale.ROOT)
                if (sub.length == 2) "$baseStr-${sub.uppercase(Locale.ROOT)}" else baseStr
            }
        }
    }

    /** Pick a TMDB image PATH: base-language, then textless, then English, then any, highest vote first. */
    private fun pickImagePath(list: JSONArray?, lang: String): String {
        if (list == null || list.length() == 0) return ""
        val rows = (0 until list.length()).mapNotNull { list.optJSONObject(it) }
            .filter { it.optString("file_path", "").isNotEmpty() }
        if (rows.isEmpty()) return ""
        fun isTextless(x: JSONObject) = !x.has("iso_639_1") || x.isNull("iso_639_1")
        val byLang = rows.filter { it.optString("iso_639_1") == lang }
        val textless = rows.filter { isTextless(it) }
        val byEnglish = rows.filter { it.optString("iso_639_1") == "en" }
        val pool = when {
            byLang.isNotEmpty() -> byLang
            textless.isNotEmpty() -> textless
            byEnglish.isNotEmpty() -> byEnglish
            else -> rows
        }
        val best = pool.maxByOrNull { it.optDouble("vote_average", 0.0) }
        return best?.optString("file_path", "") ?: ""
    }

    // MARK: disk cache

    private fun cacheFile(): File? = appContext?.let { File(it.cacheDir, "vortx-l10n-meta.json") }

    private fun loadDiskCache() {
        val file = cacheFile() ?: return
        if (!file.exists()) return
        val raw = runCatching { file.readText() }.getOrNull() ?: return
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return
        val map = HashMap<String, LocalizedMeta>()
        obj.keys().forEach { key ->
            obj.optJSONObject(key)?.let { row ->
                map[key] = LocalizedMeta(
                    row.optString("title", ""), row.optString("posterPath", ""), row.optString("logoPath", ""),
                )
            }
        }
        if (map.isNotEmpty()) _entries.value = map
    }

    private fun saveDiskCache() {
        val file = cacheFile() ?: return
        val snapshot = _entries.value
        val capped = if (snapshot.size > DISK_CACHE_CAP) {
            snapshot.entries.take(DISK_CACHE_CAP).associate { it.key to it.value }
        } else {
            snapshot
        }
        val obj = JSONObject()
        for ((key, meta) in capped) {
            obj.put(
                key,
                JSONObject()
                    .put("title", meta.title).put("posterPath", meta.posterPath).put("logoPath", meta.logoPath),
            )
        }
        runCatching { file.writeText(obj.toString()) }
    }
}

/**
 * The single place the app resolves "which language does the user want localized metadata in", as a full
 * app-language code. Apple `LocalizedMetadataLanguage`. Priority: the pinned app UI language first, then the
 * first device language mapped onto a shipped app code, else "en".
 */
object LocalizedMetadataLanguage {

    fun current(context: Context?): String {
        context ?: return "en"
        AppLanguage.current(context)?.takeIf { it.isNotEmpty() }?.let { return canonical(it) }
        deviceLanguages(context).firstOrNull()?.let { return deviceToApp(it) }
        return "en"
    }

    fun isEnglish(context: Context?): Boolean = current(context).lowercase(Locale.ROOT).startsWith("en")

    fun baseCode(context: Context?): String {
        val c = current(context)
        return (if (c.contains("-")) c.substringBefore("-") else c).lowercase(Locale.ROOT)
    }

    private fun supportedCodes(): List<String> = AppLanguage.supported.map { it.first }

    private fun canonical(raw: String): String {
        val v = raw.trim()
        if (v.isEmpty()) return "en"
        return supportedCodes().firstOrNull { it.equals(v, ignoreCase = true) } ?: v
    }

    private fun deviceToApp(id: String): String {
        val trimmed = id.trim()
        supportedCodes().firstOrNull { it.equals(trimmed, ignoreCase = true) }?.let { return it }
        val base = Locale.forLanguageTag(trimmed).language.ifEmpty { trimmed.take(2) }.lowercase(Locale.ROOT)
        supportedCodes().firstOrNull { it.equals(base, ignoreCase = true) }?.let { return it }
        return base.ifEmpty { "en" }
    }

    private fun deviceLanguages(context: Context): List<String> {
        val locales = context.resources.configuration.locales
        return (0 until locales.size()).map { locales[it].toLanguageTag() }
    }
}
