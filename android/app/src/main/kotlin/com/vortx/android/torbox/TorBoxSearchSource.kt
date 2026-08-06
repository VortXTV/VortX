package com.vortx.android.torbox

import android.util.Log
import com.vortx.android.debrid.DebridKeys
import com.vortx.android.debrid.DebridService
import com.vortx.android.engine.SourceContributorSettlement
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.sources.CanonicalContentIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
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
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume

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
/// VortX-curated list. `search-api.torbox.app` is NOT a [com.vortx.android.net.VortXEdgeAuth] gated host, so
/// no edge signing is involved.
object TorBoxSearch {

    private const val TAG = "torbox-search"
    private const val BASE = "https://search-api.torbox.app"
    private const val TIMEOUT_MS = 12_000
    private val client = OkHttpClient.Builder()
        .connectTimeout(TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
        .readTimeout(TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
        .callTimeout(TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
        .followRedirects(true)
        .build()

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
        return streams(imdbId, season, episode, apiKey) { issue ->
            issue()
            true
        }
    }

    /**
     * Credential-fenced variant. Each HTTP call is built first, then [authorizeAndIssue] atomically enqueues
     * it only if the captured credential still owns the current revision.
     */
    internal suspend fun streams(
        imdbId: String,
        season: Int? = null,
        episode: Int? = null,
        apiKey: String,
        authorizeAndIssue: (() -> Unit) -> Boolean,
    ): Result {
        if (!imdbId.startsWith("tt")) return Result(emptyList(), rateLimited = false, transportError = false)
        return coroutineScope {
            val usenet = async { fetch("usenet", imdbId, season, episode, apiKey, authorizeAndIssue) }
            val torrents = async { fetch("torrents", imdbId, season, episode, apiKey, authorizeAndIssue) }
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
    private suspend fun fetch(
        kind: String,
        imdbId: String,
        season: Int?,
        episode: Int?,
        apiKey: String,
        authorizeAndIssue: (() -> Unit) -> Boolean,
    ): Result = suspendCancellableCoroutine { continuation ->
        val query = buildString {
            append("metadata=false&check_cache=true")
            if (season != null) append("&season=").append(season)
            if (episode != null) append("&episode=").append(episode)
        }
        val request = Request.Builder()
            .url("$BASE/$kind/imdb_id:${enc(imdbId)}?$query")
            .header("Authorization", "Bearer $apiKey")
            .header("Accept", "application/json")
            .get()
            .build()
        val call = client.newCall(request)
        val completed = AtomicBoolean(false)

        fun complete(result: Result) {
            if (completed.compareAndSet(false, true)) continuation.resume(result)
        }

        continuation.invokeOnCancellation {
            completed.set(true)
            call.cancel()
        }
        val callback = object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                complete(Result(emptyList(), rateLimited = false, transportError = true))
            }

            override fun onResponse(call: Call, response: Response) {
                val result = runCatching {
                    response.use {
                        when {
                            it.code == 429 -> Result(emptyList(), rateLimited = true, transportError = false)
                            !it.isSuccessful -> Result(emptyList(), rateLimited = false, transportError = false)
                            else -> {
                                val items = parseItems(it.body?.string().orEmpty())
                                Result(items.mapNotNull(::streamFrom), rateLimited = false, transportError = false)
                            }
                        }
                    }
                }.getOrElse {
                    Result(emptyList(), rateLimited = false, transportError = false)
                }
                complete(result)
            }
        }

        val issued = runCatching {
            authorizeAndIssue { call.enqueue(callback) }
        }.getOrDefault(false)
        if (!issued) complete(Result(emptyList(), rateLimited = false, transportError = false))
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

    internal fun decodeStreams(body: String): List<StreamSource> =
        parseItems(body).mapNotNull { streamFrom(it) }

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
            return makeUsenet(
                name = "📰 $displayName",
                description = desc,
                nzbUrl = nzb,
                knownHash = item.hash?.trim()?.lowercase()?.ifEmpty { null },
            )
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
    private fun makeUsenet(
        name: String,
        description: String,
        nzbUrl: String,
        knownHash: String?,
    ): StreamSource = StreamSource(
        id = "$nzbUrl#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        nzbUrl = nzbUrl,
        usenetKnownHash = knownHash,
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
class TorBoxSearchSource private constructor(
    private val torBoxCredential: () -> Credential,
    private val authorizeAndIssue: (Credential, () -> Unit) -> Boolean,
    private val scope: CoroutineScope,
    private val fetchStreams: suspend (String, Int?, Int?, String, (() -> Unit) -> Boolean) -> TorBoxSearch.Result,
) {
    internal data class Credential(val key: String, val revision: Long)

    constructor(
        debridKeys: DebridKeys,
        /// The scope the fetch coroutines run on. Owned + cancellable via [close]; defaults to an IO scope so
        /// a caller that never provides one still works standalone (matching Apple's self-owned `Task`).
        scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
    ) : this(
        {
            debridKeys.credentialSnapshot(DebridService.TOR_BOX).let {
                Credential(it.key, it.revision)
            }
        },
        { expected, issue ->
            debridKeys.authorizeAndIssue(
                DebridService.TOR_BOX,
                expected.key,
                expected.revision,
                issue,
            )
        },
        scope,
        TorBoxSearch::streams,
    )

    /// Deterministic test seam for the asynchronous fetch boundary. Production always uses the public
    /// [DebridKeys] constructor above.
    internal constructor(
        scope: CoroutineScope,
        fetchStreams: suspend (String, Int?, Int?, String) -> TorBoxSearch.Result,
        torBoxCredential: () -> Credential = { Credential("test-key", 0L) },
    ) : this(
        torBoxCredential,
        { expected, issue ->
            if (torBoxCredential() != expected) {
                false
            } else {
                issue()
                true
            }
        },
        scope,
        { imdbId, season, episode, key, issue ->
            if (issue {}) {
                fetchStreams(imdbId, season, episode, key)
            } else {
                TorBoxSearch.Result(emptyList(), rateLimited = false, transportError = false)
            }
        },
    )

    private val _streams = MutableStateFlow<List<StreamSource>>(emptyList())

    /// The extra streams from the search index, ready to merge. Empty until a fetch completes (and always with
    /// no TorBox key). One group so the source list shows a single "TorBox Search" section. Mirrors Apple's
    /// `@Published streams`.
    val streams: StateFlow<List<StreamSource>> = _streams.asStateFlow()
    private val _settlement = MutableStateFlow(SourceContributorSettlement())
    val settlement: StateFlow<SourceContributorSettlement> = _settlement.asStateFlow()

    private val epochCounter = AtomicInteger(0)
    private val stateLock = Any()

    /// Monotonic epoch bumped whenever [streams] is REPLACED. [com.vortx.android.engine.SourceListModel] folds
    /// this into its O(1) rebuild signature (a single Int compare instead of hashing the array). Mirrors the
    /// Apple `epoch`.
    val epoch: Int get() = epochCounter.get()

    private var shownKey: String? = null
    private var shownGeneration: Long = -1L
    /// Canonical title/episode identity for the currently published rows. Read through [streamsFor] so the
    /// source-list assembler can reject a contributor snapshot owned by a different detail target.
    private var publishedContentId: String? = null
    private var inFlightKey: String? = null
    private var inFlightGeneration: Long = -1L
    private val cache = HashMap<String, List<StreamSource>>()
    private var cooldownUntilMs: Long? = null
    private var job: Job? = null
    private var activeCredentialRevision: Long? = null

    /// Fetch search results for [imdbId] if the user has a TorBox key. Fail-soft, session-cached, and backed
    /// off during a scraper cooldown. Safe to call on every meta change. Pass [season]/[episode] from an
    /// episode context so the index scopes results to that episode (null = movie level). Mirrors Apple
    /// `refresh`.
    fun refresh(
        imdbId: String?,
        season: Int? = null,
        episode: Int? = null,
        requestGeneration: Long = 0L,
    ) {
        val credential = torBoxCredential()
        val key = credential.key
        if (key.isEmpty()) {
            closeGate(credential.revision, requestGeneration)
            return
        }
        val contentId = CanonicalContentIdentity.imdb(imdbId, season, episode)
        if (contentId == null) {
            closeGate(credential.revision, requestGeneration)
            return
        }
        val canonicalImdbId = contentId.substringBefore(':')
        val fetchKey = contentId
        val launched = synchronized(stateLock) {
            replaceCredentialRevisionLocked(credential.revision)
            // New title: publish its cached results (or clear), so the prior title's streams never linger.
            if (fetchKey != shownKey || requestGeneration != shownGeneration) {
                job?.cancel()
                job = null
                inFlightKey = null
                inFlightGeneration = -1L
                shownKey = fetchKey
                shownGeneration = requestGeneration
                publishedContentId = contentId
                publishLocked(cache[fetchKey] ?: emptyList())
            }
            if (cache.containsKey(fetchKey)) {
                _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
                return
            }
            if (inFlightKey == fetchKey && inFlightGeneration == requestGeneration) {
                _settlement.value = SourceContributorSettlement(requestGeneration, settled = false)
                return
            }
            if ((cooldownUntilMs ?: 0L) > System.currentTimeMillis()) {
                _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
                return
            }

            job?.cancel()
            inFlightKey = fetchKey
            inFlightGeneration = requestGeneration
            _settlement.value = SourceContributorSettlement(requestGeneration, settled = false)
            scope.launch(start = CoroutineStart.LAZY) {
                val ownerJob = coroutineContext[Job]
                try {
                    val result = fetchStreams(canonicalImdbId, season, episode, key) { issue ->
                        authorizeAndIssue(credential, issue)
                    }
                    if (!isActive) return@launch
                    synchronized(stateLock) {
                        // A newer refresh may have canceled this fetch and claimed the slot. A late blocking
                        // response must never clear or publish over that newer request.
                        if (
                            job !== ownerJob ||
                            inFlightKey != fetchKey ||
                            inFlightGeneration != requestGeneration ||
                            shownGeneration != requestGeneration
                        ) return@synchronized
                        inFlightKey = null
                        inFlightGeneration = -1L
                        job = null
                        // A credential mutation while the request was in flight retires this result. This is
                        // the completion-side half of the gate fence; a cleared or replaced key cannot publish
                        // streams fetched under the prior credential.
                        val currentCredential = torBoxCredential()
                        if (
                            currentCredential.revision != credential.revision ||
                            currentCredential.key != key
                        ) {
                            replaceCredentialRevisionLocked(currentCredential.revision)
                            shownKey = null
                            publishedContentId = null
                            if (_streams.value.isNotEmpty()) publishLocked(emptyList())
                            return@synchronized
                        }
                        if (result.rateLimited) {
                            // Over the TorBox scraper allowance. Back off ~15 min before re-probing; do NOT
                            // cache the empty result, so it re-fetches once the cooldown lifts.
                            cooldownUntilMs = System.currentTimeMillis() + COOLDOWN_MS
                            Log.i(TAG, "rate-limited (scraper cooldown) for id=$canonicalImdbId, backing off ~15m")
                        } else if (result.transportError) {
                            // The request never completed (offline / network failure). Do NOT cache the empty
                            // result and do NOT set a cooldown, so the next meta change re-fetches.
                            Log.i(TAG, "transport error for id=$canonicalImdbId, not caching, will retry")
                        } else {
                            Log.i(TAG, "fetched ${result.streams.size} stream(s) for id=$canonicalImdbId")
                            cache[fetchKey] = result.streams
                            if (shownKey == fetchKey) publishLocked(result.streams)
                        }
                        _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
                    }
                } finally {
                    synchronized(stateLock) {
                        // Also release a fetch canceled before it could return (including a canceled scope).
                        // Identity checks keep an obsolete completion from clobbering a newer request.
                        if (
                            job === ownerJob &&
                            inFlightKey == fetchKey &&
                            inFlightGeneration == requestGeneration
                        ) {
                            inFlightKey = null
                            inFlightGeneration = -1L
                            job = null
                            _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
                        }
                    }
                }
            }.also { job = it }
        }
        launched.start()
    }

    /// Close the configured-key lifecycle synchronously. A detail target installs its new generation only
    /// after [refresh] returns, so clearing the prior target here prevents its streams from being relabeled as
    /// the new target when the key gate is closed. A new credential revision also retires cache and cooldown.
    private fun closeGate(credentialRevision: Long, requestGeneration: Long) {
        synchronized(stateLock) {
            replaceCredentialRevisionLocked(credentialRevision)
            job?.cancel()
            job = null
            inFlightKey = null
            inFlightGeneration = -1L
            shownKey = null
            shownGeneration = -1L
            publishedContentId = null
            if (_streams.value.isNotEmpty()) publishLocked(emptyList())
            _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
        }
    }

    /** Caller holds [stateLock]. Credential changes retire every result and cooldown from the prior key. */
    private fun replaceCredentialRevisionLocked(revision: Long) {
        if (activeCredentialRevision == revision) return
        activeCredentialRevision = revision
        job?.cancel()
        job = null
        inFlightKey = null
        inFlightGeneration = -1L
        shownKey = null
        shownGeneration = -1L
        publishedContentId = null
        cache.clear()
        cooldownUntilMs = null
        if (_streams.value.isNotEmpty()) publishLocked(emptyList())
    }

    data class Snapshot(val streams: List<StreamSource>, val epoch: Int)

    /// Snapshot the epoch and only rows whose canonical title/episode identity owns [contentId]. Taking all
    /// three values under the contributor lock keeps the assembler from memoizing old rows with a new epoch.
    fun snapshotFor(contentId: String?): Snapshot = synchronized(stateLock) {
        Snapshot(
            streams = if (contentId != null && publishedContentId == contentId) _streams.value else emptyList(),
            epoch = epochCounter.get(),
        )
    }

    fun streamsFor(contentId: String?): List<StreamSource> = snapshotFor(contentId).streams

    /// Empty the PUBLISHED results (and the shown-key, so a later refresh for the same title re-publishes from
    /// cache instead of being deduped into staying empty) WITHOUT touching the session cache, the in-flight
    /// bookkeeping, or the scraper-cooldown state (those protect the TorBox allowance for the whole session).
    /// Mirrors Apple `clearResults`. A still-in-flight fetch is left running ON PURPOSE (the shownKey guard
    /// already blocks a stale publish).
    fun clearResults() {
        synchronized(stateLock) {
            shownKey = null
            shownGeneration = -1L
            publishedContentId = null
            if (_streams.value.isNotEmpty()) publishLocked(emptyList())
        }
    }

    /** Cancel all work and clear rows when the profile/source owner changes. */
    fun reset(requestGeneration: Long, clearCache: Boolean = false) {
        synchronized(stateLock) {
            job?.cancel()
            job = null
            inFlightKey = null
            inFlightGeneration = -1L
            shownKey = null
            shownGeneration = -1L
            publishedContentId = null
            if (clearCache) cache.clear()
            if (_streams.value.isNotEmpty()) publishLocked(emptyList())
            _settlement.value = SourceContributorSettlement(requestGeneration, settled = true)
        }
    }

    /// Cancel any in-flight fetch and tear down the owned scope. Call when the owning screen goes away.
    fun close() {
        synchronized(stateLock) {
            job?.cancel()
            job = null
            inFlightKey = null
            inFlightGeneration = -1L
        }
        scope.coroutineContext[Job]?.cancel()
    }

    /// Merge the fetched search streams into [groups] as one extra group. Returns [groups] unchanged when
    /// there is nothing to add. Mirrors Apple `merged(into:)`.
    fun merged(into: List<StreamGroup>): List<StreamGroup> = merge(_streams.value, into)

    /// Caller holds [stateLock].
    private fun publishLocked(value: List<StreamSource>) {
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
