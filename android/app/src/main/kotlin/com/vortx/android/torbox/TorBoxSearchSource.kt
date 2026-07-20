package com.vortx.android.torbox

import android.util.Log
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridService
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicInteger

/// TorBox SEARCH-as-a-source: the Kotlin port of Apple `app/SourcesShared/TorBoxSearchSource.swift`.
///
/// A lightweight client for `search-api.torbox.app` (a PUBLIC, IP-rate-limited search index, SEPARATE from
/// the account API `api.torbox.app` the [com.vortx.android.debrid.DebridResolver] talks to). For the current
/// title's imdb id it pulls both usenet and torrent results and turns them into extra [StreamSource]s that
/// MERGE into the source list the user sees, so a user with a TorBox key gets usenet AND torrent sources
/// with NO usenet/torrent add-on installed.
///
/// GATED on a TorBox key ([DebridKeys.isConfigured] for [DebridService.TOR_BOX]): with no key the whole
/// feature no-ops (no fetch, no extra sources). The key is passed as the Bearer to lift the anonymous rate
/// limit. FAIL-SOFT: any error / timeout yields no extra sources and no user-visible failure. It never blocks
/// the normal add-on stream load, mirroring the async-contribution shape of the media-server source.
///
/// NO referral / partnership code: these are the user's own search results against the public index, not a
/// VortX-curated list. HTTP is [HttpURLConnection] and JSON is `org.json`, matching the existing debrid layer
/// (`search-api.torbox.app` is NOT a [com.vortx.android.net.VortXEdgeAuth] gated host, so no edge signing).
object TorBoxSearch {

    private const val TAG = "torbox-search"
    private const val BASE = "https://search-api.torbox.app"
    private const val TIMEOUT_MS = 12_000

    /// Combined usenet + torrent results plus two signal flags. [rateLimited] is true when the index answered
    /// 429 (the account is over its TorBox scraper allowance / in the daily search cooldown), so the caller
    /// backs off instead of re-firing on the next title and burning more of the quota. [transportError] is
    /// true when a leg's request never completed (offline, DNS/TLS failure, timeout), so the caller keeps the
    /// empty result OUT of the session cache and re-fetches once the network is back. Mirrors the Apple tuple.
    data class Result(
        val streams: List<StreamSource>,
        val rateLimited: Boolean,
        val transportError: Boolean,
    )

    /// One usenet/torrent result parsed from the search index. Tolerant: the index wraps items under
    /// `data.nzbs` / `data.torrents` and field names vary, so every field is optional and read defensively.
    /// Mirrors Apple `TorBoxSearch.Response.Item`.
    private data class Item(
        val hash: String?,
        val rawTitle: String?,
        val title: String?,
        val magnet: String?,
        val nzb: String?,
        val link: String?,
        val size: Long?,
        val seeders: Int?,
        val age: String?,
        val type: String?,
        val cached: Boolean?,
    )

    /// Fetch usenet + torrent search results for an imdb id and flatten to extra streams. Returns an empty
    /// [Result] on any failure (no key handled by the caller's gate; a network error / decode failure /
    /// timeout all collapse to empty). [apiKey] lifts the anonymous rate limit (keyless requests always 429).
    /// [season]/[episode] scope a series fetch to one episode; null for movies. Mirrors Apple `streams`.
    suspend fun streams(imdbId: String, season: Int? = null, episode: Int? = null, apiKey: String): Result {
        if (!imdbId.startsWith("tt")) return Result(emptyList(), rateLimited = false, transportError = false)
        return coroutineScope {
            val usenet = async { fetch("usenet", imdbId, season, episode, apiKey) }
            val torrents = async { fetch("torrents", imdbId, season, episode, apiKey) }
            val (u, t) = awaitAll(usenet, torrents)
            Result(
                streams = u.streams + t.streams,
                rateLimited = u.rateLimited || t.rateLimited,
                transportError = u.transportError || t.transportError,
            )
        }
    }

    /// One `GET /{kind}/imdb_id:{id}` call, bounded and fail-soft. The id-type prefix must be `imdb_id:`
    /// (the index's IdType name); `imdb:` is unknown to it and returns nothing. Auth is the Bearer header ONLY
    /// (the JSON endpoints take no `apikey` query param, and the key must not ride in URLs anyway); anonymous
    /// requests are hard-429'd. `check_cache=true` asks the index to flag which results the account already has
    /// cached. Mirrors Apple `fetch`.
    private suspend fun fetch(kind: String, imdbId: String, season: Int?, episode: Int?, apiKey: String): Result =
        withContext(Dispatchers.IO) {
            val query = buildString {
                append("metadata=false&check_cache=true")
                if (season != null) append("&season=").append(season)
                if (episode != null) append("&episode=").append(episode)
            }
            val url = "$BASE/$kind/imdb_id:${enc(imdbId)}?$query"
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = TIMEOUT_MS
                    readTimeout = TIMEOUT_MS
                    useCaches = false
                    instanceFollowRedirects = true
                    setRequestProperty("Authorization", "Bearer $apiKey")
                    setRequestProperty("Accept", "application/json")
                }
                val code = conn.responseCode
                // 429 = over the TorBox scraper allowance (the account's daily search cooldown). The index
                // returns "Rate limit exceeded: 0 per 1 minute" for EVERY search until the cooldown resets
                // (~24h), so surface it as a distinct signal instead of an empty "no results".
                if (code == 429) return@withContext Result(emptyList(), rateLimited = true, transportError = false)
                if (code !in 200..299) return@withContext Result(emptyList(), rateLimited = false, transportError = false)
                val body = conn.inputStream.bufferedReader().use(BufferedReader::readText)
                val items = parseItems(body)
                Result(items.mapNotNull { streamFrom(it) }, rateLimited = false, transportError = false)
            } catch (io: IOException) {
                // A request that never completed (offline, DNS/TLS failure, timeout) yields no HTTP response.
                // Report it as a distinct transportError so the caller does not cache the empty result as "no
                // results" for the session; that is what made an offline first open stick until relaunch.
                Result(emptyList(), rateLimited = false, transportError = true)
            } catch (t: Throwable) {
                Result(emptyList(), rateLimited = false, transportError = false)
            } finally {
                conn?.disconnect()
            }
        }

    /// Tolerant org.json decode of the `data.nzbs` + `data.torrents` arrays. One bad field must not sink the
    /// whole response, so every read is defensive and `size` rides as a number OR a numeric string.
    private fun parseItems(body: String): List<Item> {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return emptyList()
        val data = root.optJSONObject("data") ?: return emptyList()
        val out = ArrayList<Item>()
        appendArray(data.optJSONArray("nzbs"), out)
        appendArray(data.optJSONArray("torrents"), out)
        return out
    }

    private fun appendArray(arr: JSONArray?, into: MutableList<Item>) {
        if (arr == null) return
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val knownSeeders = if (o.has("last_known_seeders") && !o.isNull("last_known_seeders")) {
                o.optInt("last_known_seeders", -1)
            } else {
                -1
            }
            into.add(
                Item(
                    hash = o.optStringOrNull("hash"),
                    rawTitle = o.optStringOrNull("raw_title"),
                    title = o.optStringOrNull("title"),
                    magnet = o.optStringOrNull("magnet"),
                    nzb = o.optStringOrNull("nzb"),
                    link = o.optStringOrNull("link"),
                    size = parseSize(o.opt("size")),
                    seeders = if (knownSeeders >= 0) knownSeeders else null,
                    age = o.optStringOrNull("age"),
                    type = o.optStringOrNull("type"),
                    cached = if (o.has("cached") && !o.isNull("cached")) o.optBoolean("cached") else null,
                ),
            )
        }
    }

    /// `size` coerces from a JSON number OR a numeric string (the index emits both), null when absent/garbage.
    private fun parseSize(raw: Any?): Long? = when (raw) {
        is Number -> raw.toLong()
        is String -> raw.toDoubleOrNull()?.toLong()
        else -> null
    }

    /// Build a [StreamSource] from one search item. Usenet vs torrent is discriminated by the index's own
    /// `type` field / the presence of an nzb link, NEVER by hash-emptiness: EVERY item carries a non-empty
    /// `hash` (for usenet it is the NZB md5), so keying usenet on an empty hash mis-mapped every usenet result
    /// into a bogus torrent. Items with neither identity are dropped. Mirrors Apple `stream(from:)`.
    private fun streamFrom(item: Item): StreamSource? {
        val displayName = item.rawTitle ?: item.title ?: "TorBox Search"
        val sizeSuffix = item.size?.let { " · ${humanSize(it)}" }.orEmpty()
        // The index's own cache-check (`check_cache=true`): a text marker so StreamRanking.isCached lights the
        // cache badge + within-tier cache bonus with no extra provider round trip.
        val cachedSuffix = if (item.cached == true) " · ⚡ Cached" else ""

        // USENET: typed usenet by the index, or carrying an nzb link.
        if (item.type?.lowercase() == "usenet" || !item.nzb.isNullOrEmpty()) {
            val nzb = (item.nzb ?: item.link).orEmpty()
            if (nzb.isEmpty() || !nzb.lowercase().startsWith("http")) return null
            val desc = "TorBox Usenet$sizeSuffix$cachedSuffix"
            return makeUsenet(name = "📰 $displayName", description = desc, nzbUrl = nzb)
        }

        // TORRENT: an infohash (or a magnet we can pull one from).
        val hash = torrentHash(item)
        if (!hash.isNullOrEmpty()) {
            val seeders = item.seeders?.let { " · 👤 $it" }.orEmpty()
            val desc = "TorBox Search$sizeSuffix$seeders$cachedSuffix"
            return makeTorrent(name = displayName, description = desc, infoHash = hash.lowercase())
        }
        return null
    }

    /// A torrent item's infohash: the explicit `hash`, else parsed from the magnet `xt=urn:btih:`. Mirrors
    /// Apple `torrentHash`.
    private fun torrentHash(item: Item): String? {
        if (!item.hash.isNullOrEmpty()) return item.hash
        val magnet = item.magnet ?: return null
        val idx = magnet.indexOf("btih:", ignoreCase = true)
        if (idx < 0) return null
        val after = magnet.substring(idx + "btih:".length)
        val hex = after.takeWhile { it.isHexDigit() }
        return hex.ifEmpty { null }
    }

    /// A raw torrent search stream: the infohash is both the id handle (so the debrid resolve path reads it
    /// verbatim) and the [StreamSource.infoHash] the ranker tiers on. [StreamSource.isTorrent] = true so the
    /// ranker classifies it as a torrent (Android has no `sources` trackers field, so magnet trackers are
    /// dropped; the debrid resolve keys on the infohash alone).
    private fun makeTorrent(name: String, description: String, infoHash: String): StreamSource = StreamSource(
        id = "$infoHash#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        isTorrent = true,
        infoHash = infoHash,
    )

    /// A usenet search stream: a non-null [StreamSource.nzbUrl] with no [StreamSource.url] makes the ranker
    /// report `isUsenet`, so the existing TorBox usenet resolve path plays it with the user's own account.
    private fun makeUsenet(name: String, description: String, nzbUrl: String): StreamSource = StreamSource(
        id = "$nzbUrl#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        nzbUrl = nzbUrl,
    )

    /// A binary byte size ("12.4 GB" / "850 MB") in the shape StreamRanking's size regex reads (locale-US so
    /// the decimal separator is always '.'). Mirrors Apple `ByteCountFormatter(.binary)`.
    private fun humanSize(bytes: Long): String {
        if (bytes <= 0) return ""
        val gb = bytes / 1_073_741_824.0
        if (gb >= 1.0) return String.format(java.util.Locale.US, "%.1f GB", gb)
        val mb = bytes / 1_048_576.0
        if (mb >= 1.0) return String.format(java.util.Locale.US, "%.0f MB", mb)
        val kb = bytes / 1024.0
        return String.format(java.util.Locale.US, "%.0f KB", kb)
    }

    /// The stable group label the merged TorBox search sources render under (matches Apple's
    /// `CoreStreamSourceGroup(addon: "TorBox Search")`).
    const val GROUP_ADDON = "TorBox Search"

    /// The stable group id [TorBoxSearchSource.merge] stamps, so a source-list UI can find it without a magic
    /// string.
    const val GROUP_ID = "vortx.torbox.search"

    // ---- org.json helpers (org.json returns the string "null" from optString) ----

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    private fun Char.isHexDigit(): Boolean = this in '0'..'9' || this in 'a'..'f' || this in 'A'..'F'

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}

/// A per-detail-view contributor that fetches TorBox search results for the current title and publishes them
/// as an extra source group to MERGE into the list (mirrors the media-server contributor shape). Gated on a
/// TorBox key; no key = no fetch = empty group = the list is unchanged. De-dups by imdb id so a re-render of
/// the same title does not re-hit the index. The Kotlin port of Apple `TorBoxSearchSource` (the `@StateObject`
/// class): `@Published streams` becomes a [StateFlow], the SwiftUI `Task` becomes a coroutine [Job] on an
/// owned scope, and the session cache / cooldown / in-flight bookkeeping is preserved field-for-field.
class TorBoxSearchSource(
    private val debridKeys: DebridKeys,
    /// The scope the fetch coroutines run on. Owned + cancellable via [close]; defaults to an IO scope so a
    /// caller that never provides one still works standalone (matching Apple's self-owned `Task`).
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val _streams = MutableStateFlow<List<StreamSource>>(emptyList())

    /// The extra streams from the search index, ready to merge. Empty until a fetch completes (and always with
    /// no TorBox key). One group so the source list shows a single "TorBox Search" section. Mirrors Apple's
    /// `@Published streams`.
    val streams: StateFlow<List<StreamSource>> = _streams.asStateFlow()

    private val epochCounter = AtomicInteger(0)

    /// Monotonic epoch bumped whenever [streams] is REPLACED. [com.vortx.android.engine.SourceListModel] folds
    /// this into its O(1) rebuild signature (a single Int compare instead of hashing the array). Mirrors the
    /// Apple `epoch`.
    val epoch: Int get() = epochCounter.get()

    private var shownKey: String? = null
    private var inFlightKey: String? = null
    private val cache = HashMap<String, List<StreamSource>>()
    private var cooldownUntilMs: Long? = null
    private var job: Job? = null

    /// Fetch search results for [imdbId] if the user has a TorBox key. Fail-soft, session-cached, and backed
    /// off during a scraper cooldown. Safe to call on every meta change. Pass [season]/[episode] from an
    /// episode context so the index scopes results to that episode (null = movie level). Mirrors Apple
    /// `refresh`.
    fun refresh(imdbId: String?, season: Int? = null, episode: Int? = null) {
        if (imdbId == null || !imdbId.startsWith("tt")) return
        if (!debridKeys.isConfigured(DebridService.TOR_BOX)) return // gate: no TorBox key -> no-op
        val fetchKey = "$imdbId|${season ?: -1}|${episode ?: -1}"
        // New title: publish its cached results (or clear), so the prior title's streams never linger.
        if (fetchKey != shownKey) {
            shownKey = fetchKey
            publish(cache[fetchKey] ?: emptyList())
        }
        if (cache.containsKey(fetchKey)) return // cached: already published above, no round trip
        if (inFlightKey == fetchKey) return // the paired refreshes for this id: fetch once
        cooldownUntilMs?.let { if (it > System.currentTimeMillis()) return } // in scraper cooldown: don't burn
        job?.cancel()
        inFlightKey = fetchKey
        val key = debridKeys.key(DebridService.TOR_BOX)
        job = scope.launch {
            val result = TorBoxSearch.streams(imdbId, season, episode, apiKey = key)
            if (!isActive) return@launch
            inFlightKey = null
            if (result.rateLimited) {
                // Over the TorBox scraper allowance. Back off ~15 min before re-probing; do NOT cache the
                // empty result, so it re-fetches once the cooldown lifts.
                cooldownUntilMs = System.currentTimeMillis() + COOLDOWN_MS
                Log.i(TAG, "rate-limited (scraper cooldown) for id=$imdbId, backing off ~15m")
                return@launch
            }
            if (result.transportError) {
                // The request never completed (offline / network failure). Do NOT cache the empty result and
                // do NOT set a cooldown, so the next meta change re-fetches once the network is back.
                Log.i(TAG, "transport error for id=$imdbId, not caching, will retry")
                return@launch
            }
            Log.i(TAG, "fetched ${result.streams.size} stream(s) for id=$imdbId")
            cache[fetchKey] = result.streams
            if (shownKey == fetchKey) publish(result.streams)
        }
    }

    /// Empty the PUBLISHED results (and the shown-key, so a later refresh for the same title re-publishes from
    /// cache instead of being deduped into staying empty) WITHOUT touching the session cache, the in-flight
    /// bookkeeping, or the scraper-cooldown state (those protect the TorBox allowance for the whole session).
    /// Mirrors Apple `clearResults`. A still-in-flight fetch is left running ON PURPOSE (the shownKey guard
    /// already blocks a stale publish).
    fun clearResults() {
        shownKey = null
        if (_streams.value.isNotEmpty()) publish(emptyList())
    }

    /// Cancel any in-flight fetch and tear down the owned scope. Call when the owning screen goes away.
    fun close() {
        job?.cancel()
        scope.coroutineContext[Job]?.cancel()
    }

    /// Merge the fetched search streams into [groups] as one extra group. Returns [groups] unchanged when
    /// there is nothing to add. Mirrors Apple `merged(into:)`.
    fun merged(into: List<StreamGroup>): List<StreamGroup> = merge(_streams.value, into)

    private fun publish(value: List<StreamSource>) {
        _streams.value = value
        epochCounter.incrementAndGet()
    }

    companion object {
        private const val TAG = "torbox-search"
        private const val COOLDOWN_MS = 15L * 60L * 1000L

        /// The pure merge: append the fetched search streams as one extra group, deduped against the streams
        /// already present (by infoHash for torrents, nzbUrl for usenet, url otherwise). Returns [groups]
        /// unchanged when there is nothing to add, so a no-key / empty-result path is a pure pass-through.
        /// Mirrors Apple `TorBoxSearchSource.merge`.
        fun merge(extra: List<StreamSource>, groups: List<StreamGroup>): List<StreamGroup> {
            if (extra.isEmpty()) return groups
            val seenHashes = HashSet<String>()
            val seenNzb = HashSet<String>()
            val seenUrls = HashSet<String>()
            for (group in groups) {
                for (s in group.streams) {
                    s.infoHash?.lowercase()?.let { seenHashes.add(it) }
                    s.nzbUrl?.let { seenNzb.add(it) }
                    s.url?.let { seenUrls.add(it) }
                }
            }
            val fresh = extra.filter { s ->
                val h = s.infoHash?.lowercase()
                val n = s.nzbUrl
                val u = s.url
                when {
                    h != null -> h !in seenHashes
                    n != null -> n !in seenNzb
                    u != null -> u !in seenUrls
                    else -> true
                }
            }
            if (fresh.isEmpty()) return groups
            Log.d(TAG, "merged ${fresh.size} new row(s) into ${groups.size} group(s)")
            return groups + StreamGroup(addon = TorBoxSearch.GROUP_ADDON, streams = fresh)
        }
    }
}
