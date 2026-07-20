package com.vortx.android.singularity

import android.util.Log
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicInteger

private val CANONICAL_INFOHASH = Regex("""^[0-9a-f]{40}$""")
private val CANONICAL_CONTENT_ID = Regex("""^(tt[0-9]{6,10}|tmdb:[0-9]{1,10})(:[0-9]{1,4}:[0-9]{1,4})?$""")

/// Client for VortX's community SOURCE INDEX at `sources.vortx.tv` ("Singularity"): the Kotlin port of Apple
/// `app/SourcesShared/SourceIndexClient.swift`. The pooled record of which torrent sources exist for a title,
/// corroborated across users.
///
/// TWO halves, both fully fail-soft (any miss / error / offline is a silent no-op; nothing ever blocks or
/// slows playback or a screen):
///
///   1. HOARD (available only after the hard gate is wired): when enabled, assembled stream results report the
///      source DESCRIPTORS, NOT the media, NOT any account token or user id. A descriptor is only
///      { kind, id, quality, sizeBytes, seeders? } where `id` is an exact 40-hex torrent infohash. Raw HTTP and
///      usenet URLs are never uploaded. Fire-and-forget, batched, deduped by infohash.
///
///   2. SERVE (opt-in): when the user turns the Singularity toggle ON AND is signed in, the detail screen
///      reads corroborated torrent infohashes and MERGES them into the stream list for the user's debrid
///      pipeline. HTTP and usenet have no v1 consumer contract and are dropped. Empty on any miss; signed-out
///      disables the read entirely (hard login gate, matching the worker).
///
/// GATING (VortX-only): `sources.vortx.tv` is a [VortXEdgeAuth] gated host, so BOTH the POST and the GET are
/// HMAC-signed. Signing is a safe no-op without a provisioned secret (the worker's observe mode allows it).
///
/// ANDROID AVAILABILITY: this client is deliberately dormant because Android has no canonical give-to-get
/// consent, SourceIndex fleet switch, VortX-account identity, X-VX-Moat token, or bounded streamed transport
/// surface. Re-enable also requires pinning the exact baked origin and refusing every redirect. Consent, fleet,
/// account, and moat must be live lifecycle gates whose closure cancels in-flight SERVE, clears published
/// sources, and prevents late publication. [isEnabled] remains false until a separate lane wires and verifies
/// all six surfaces and receives independent security sign-off. Before that
/// re-enable, the process ledger must also move from SourceListModel beside this client's pacer, claim each
/// <=16 chunk after pacing immediately before POST without eviction, and gain cancellation/overlap tests.
/// Extraction and
/// reconstruction stay compiled and tested, but neither HOARD nor SERVE can touch the network while disabled.
object SourceIndexClient {

    private const val TAG = "sing"

    // MARK: - Public models

    /// Torrent-only v1 has one wire kind.
    enum class Kind(val wire: String) { TORRENT("torrent") }

    /// One anonymized source descriptor for the HOARD upload. Carries ONLY public, non-personal fields.
    /// Mirrors Apple `Descriptor`.
    data class Descriptor(
        val kind: String,
        val id: String, // normalized 40-hex torrent infohash
        val quality: String, // e.g. "4K", "1080p", "Other" (from StreamRanking.qualityLabel)
        val sizeBytes: Long, // 0 when the add-on advertised no size
        val seeders: Int?, // when advertised
    )

    /// One corroborated source the pool returns for SERVE. `id` matches the descriptor id space. Mirrors
    /// Apple `PooledSource`.
    data class PooledSource(
        val kind: String?,
        val id: String?,
        val quality: String?,
        val sizeBytes: Long?,
        val seeders: Int?,
        val corroboration: Int?,
    )

    // MARK: - Content id (colon form: imdb[:season:episode])

    /// The pool `content_id` for a title, in the worker's colon form (`tt0903747` for a movie, `tt…:S:E` for an
    /// episode). null when the id is not a real imdb `tt…` id. Mirrors Apple `contentID`.
    fun contentId(imdbId: String?, season: Int? = null, episode: Int? = null): String? {
        if (imdbId == null) return null
        if (!Regex("""^tt[0-9]{6,10}$""").matches(imdbId)) return null
        val contentId = if (season != null && episode != null) "$imdbId:$season:$episode" else imdbId
        return canonicalContentId(contentId)
    }

    // MARK: - Descriptor extraction (pure; no user data)

    /// Build the anonymized descriptor set for a title's assembled source groups. Uses [StreamRanking] as the
    /// single source of truth for quality / size / seeders, so the pool's view matches the app's. Skips
    /// YouTube trailers and every stream without an exact 40-hex torrent infohash. Deduped by normalized
    /// infohash. Mirrors Apple `descriptors(from:)`.
    fun descriptors(groups: List<StreamGroup>): List<Descriptor> {
        val seen = HashSet<String>()
        val out = ArrayList<Descriptor>()
        for (group in groups) {
            for (stream in group.streams) {
                if (stream.isYouTubeTrailer) continue
                val d = descriptor(stream) ?: continue
                if (seen.add(d.kind + "|" + d.id)) out.add(d)
            }
        }
        return out
    }

    /// One descriptor for one stream, or null when it has no canonical torrent identity. A debrid-resolved URL
    /// may be personal, so only the public torrent infohash crosses this boundary. Mirrors Apple
    /// `descriptor(for:)`.
    private fun descriptor(stream: StreamSource): Descriptor? {
        val sizeGb = StreamRanking.sizeForSort(stream) // GB (0 when unknown)
        val sizeBytes = if (sizeGb > 0) Math.round(sizeGb * 1024.0 * 1024.0 * 1024.0) else 0L
        val quality = StreamRanking.qualityLabel(stream)

        val hash = normalizeInfoHash(stream.infoHash) ?: return null
        val seeders = StreamRanking.seedersForSort(stream)
        return Descriptor(
            Kind.TORRENT.wire,
            hash,
            quality,
            sizeBytes,
            seeders = if (seeders >= 0) seeders else null,
        )
    }

    // MARK: - HOARD: POST /sources/contribute (signed, fire-and-forget)

    /// Report the assembled source descriptors for a title. Gated on the feature flag. Popular titles resolve
    /// far more than one POST can carry (the worker rejects a POST above MAX_SOURCES_PER_CONTRIBUTE = 16), so we chunk
    /// the whole deduped set into [BATCH_SIZE]-descriptor POSTs. The process-wide [uploadPacer] serializes all
    /// callers and spaces every POST by [INTER_BATCH_DELAY_MS], so overlapping title rebuilds cannot multiply
    /// the worker's per-IP request rate. Each POST is independently fire-and-forget. No-op on an empty set.
    /// Mirrors Apple `contribute`.
    suspend fun contribute(contentId: String, descriptors: List<Descriptor>) {
        contributeUsing(contentId, descriptors) { id, chunk, index, total ->
            postBatch(id, chunk, index, total)
        }
    }

    /// Internal transport seam used to prove that the hard availability gate prevents every POST attempt.
    internal suspend fun contributeUsing(
        contentId: String,
        descriptors: List<Descriptor>,
        post: suspend (String, List<Descriptor>, Int, Int) -> Unit,
    ) {
        if (!isEnabled || canonicalContentId(contentId) != contentId) return
        // Revalidate at the network boundary. Descriptor is a simple value type and can be constructed without
        // descriptors(groups), so only torrent-only canonical identities are allowed to reach the encoder.
        val batches = uploadBatches(descriptors)
        if (batches.isEmpty()) return
        withContext(Dispatchers.IO) {
            for ((i, chunk) in batches.withIndex()) {
                if (!isActive) return@withContext
                uploadPacer.pace {
                    if (isActive) post(contentId, chunk, i + 1, batches.size)
                }
            }
        }
    }

    /// Convenience: extract descriptors from [groups] and contribute them for [contentId]. The HOARD entry the
    /// assembly (SourceListModel) calls once a title's ranked list is built. Mirrors Apple `hoard`.
    suspend fun hoard(contentId: String, groups: List<StreamGroup>) {
        if (!isEnabled) return
        contribute(contentId, descriptors(groups))
    }

    private fun postBatch(contentId: String, chunk: List<Descriptor>, index: Int, total: Int) {
        val body = contributionBody(contentId, chunk) ?: return

        var conn: HttpURLConnection? = null
        try {
            conn = (URL("$BASE_URL/sources/contribute").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = HTTP_TIMEOUT_MS
                readTimeout = HTTP_TIMEOUT_MS
                useCaches = false
                instanceFollowRedirects = false
                doOutput = true
                setRequestProperty("content-type", "application/json")
            }
            VortXEdgeAuth.sign(conn) // gated host: stamp X-VX-Ts / X-VX-Sig / X-VX-Kid
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            Log.d(TAG, "contribute POST content=$contentId batch=$index/$total descriptors=${chunk.size}")
            conn.responseCode // fire-and-forget: a 429 / error just drops this batch
        } catch (_: Throwable) {
            // fire-and-forget: any failure silently drops this one batch, never blocks or crashes playback
        } finally {
            conn?.disconnect()
        }
    }

    /// Pure wire encoder kept visible to deterministic unit tests. The closed DTO makes it impossible for a
    /// stream URL, NZB URL, or provider tag to enter the upload JSON.
    internal fun contributionBody(contentId: String, chunk: List<Descriptor>): String? {
        if (canonicalContentId(contentId) != contentId || chunk.isEmpty() || chunk.size > BATCH_SIZE) return null
        val sources = uploadableDescriptors(chunk)
        if (sources.isEmpty()) return null
        return JSONObject().apply {
            put("content_id", contentId)
            val arr = JSONArray()
            for (d in sources) {
                arr.put(
                    JSONObject().apply {
                        put("kind", d.kind)
                        put("id", d.id)
                        put("quality", d.quality)
                        put("sizeBytes", d.sizeBytes)
                        if (d.seeders != null) put("seeders", d.seeders)
                    },
                )
            }
            put("sources", arr)
        }.toString()
    }

    /// Final upload-boundary validation for arbitrary descriptors, deduped by normalized infohash. Both the
    /// network path and its wire encoder call this so a future caller cannot bypass the torrent-only contract.
    internal fun uploadableDescriptors(descriptors: List<Descriptor>): List<Descriptor> {
        val seen = HashSet<String>()
        return descriptors.mapNotNull { descriptor ->
            if (descriptor.kind != Kind.TORRENT.wire) return@mapNotNull null
            val hash = normalizeInfoHash(descriptor.id) ?: return@mapNotNull null
            if (!seen.add(hash)) return@mapNotNull null
            descriptor.copy(
                kind = Kind.TORRENT.wire,
                id = hash,
                quality = normalizeQuality(descriptor.quality),
                sizeBytes = descriptor.sizeBytes.coerceIn(0, MAX_SAFE_SIZE_BYTES),
                seeders = descriptor.seeders?.takeIf { it in 0..MAX_SEEDERS },
            )
        }
    }

    /// Pure final normalization and worker-cap chunking, kept visible for parity tests with Apple and the worker.
    internal fun uploadBatches(descriptors: List<Descriptor>): List<List<Descriptor>> =
        uploadableDescriptors(descriptors).take(MAX_DESCRIPTORS_PER_TITLE).chunked(BATCH_SIZE)

    // MARK: - SERVE: GET /sources?content_id=… (signed, opt-in + login-gated)

    /// Read the corroborated pooled sources for [contentId]. Returns `[]` unless the Singularity SERVE toggle
    /// is on AND the user is signed in AND the fleet flag is on. Fail-soft to `[]` on any error or when
    /// disabled. Mirrors Apple `fetchPooled`.
    suspend fun fetchPooled(contentId: String, isSignedIn: Boolean): List<PooledSource> {
        return fetchPooledUsing(
            contentId = contentId,
            isSignedIn = isSignedIn,
            moatProvider = { runCatching { moatTokenProvider?.invoke() }.getOrNull() },
            request = ::fetchPooledNetwork,
        )
    }

    /// Internal transport seam used to prove that the hard availability gate prevents token and GET work.
    internal suspend fun fetchPooledUsing(
        contentId: String,
        isSignedIn: Boolean,
        moatProvider: suspend () -> String?,
        request: suspend (String, String, String?) -> List<PooledSource>,
    ): List<PooledSource> {
        // Validate before logging or constructing a request. A caller-controlled or user-shaped value must not
        // enter telemetry or the query string even when a future call site bypasses contentId().
        val url = serveUrl(contentId) ?: return emptyList()
        Log.d(TAG, "fetchPooled GATE contentId=$contentId isEnabled=$isEnabled serveEnabled=$serveEnabled isSignedIn=$isSignedIn")
        if (!isEnabled || !serveEnabled || !isSignedIn) {
            Log.d(TAG, "fetchPooled GATE CLOSED contentId=$contentId -> [] (gate off / not signed in)")
            return emptyList()
        }
        val moat = moatProvider()
        return request(url, contentId, moat)
    }

    private suspend fun fetchPooledNetwork(
        url: String,
        contentId: String,
        moat: String?,
    ): List<PooledSource> {
        return withContext(Dispatchers.IO) {
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = HTTP_TIMEOUT_MS
                    readTimeout = HTTP_TIMEOUT_MS
                    useCaches = false
                    instanceFollowRedirects = false
                    setRequestProperty("accept", "application/json")
                }
                VortXEdgeAuth.sign(conn)
                // Moat token: the SERVE gate is login-only AND moat-token-gated. Stamp X-VX-Moat after the edge
                // signature when a provider is wired. Fail-soft: no token -> no header -> the worker returns
                // empty, the correct signed-out / cold-start SERVE result.
                if (moat != null) conn.setRequestProperty(MOAT_HEADER, moat)
                val code = conn.responseCode
                if (code !in 200..299) {
                    Log.d(TAG, "fetchPooled HTTP non-2xx contentId=$contentId status=$code -> []")
                    return@withContext emptyList()
                }
                // This reader remains unreachable while isEnabled is the compile-time false gate. Before any
                // re-enable, replace it with the separately reviewed bounded streamed transport (surface five).
                val text = conn.inputStream.bufferedReader().use(BufferedReader::readText)
                val sources = parsePooled(text)
                Log.d(TAG, "fetchPooled HTTP OK contentId=$contentId status=$code corroboratedSources=${sources.size}")
                sources
            } catch (io: IOException) {
                Log.d(TAG, "fetchPooled HTTP ERROR contentId=$contentId error=${io.message} -> []")
                emptyList()
            } catch (t: Throwable) {
                emptyList()
            } finally {
                conn?.disconnect()
            }
        }
    }

    internal fun parsePooled(body: String): List<PooledSource> {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return emptyList()
        val arr = root.optJSONArray("sources") ?: return emptyList()
        val acceptedCount = minOf(arr.length(), MAX_SERVE_RESULTS)
        val out = ArrayList<PooledSource>(acceptedCount)
        for (i in 0 until acceptedCount) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                PooledSource(
                    kind = o.optStringOrNull("kind"),
                    id = o.optStringOrNull("id"),
                    quality = o.optStringOrNull("quality"),
                    sizeBytes = if (o.has("sizeBytes") && !o.isNull("sizeBytes")) o.optLong("sizeBytes") else null,
                    seeders = if (o.has("seeders") && !o.isNull("seeders")) o.optInt("seeders") else null,
                    corroboration = if (o.has("corroboration") && !o.isNull("corroboration")) o.optInt("corroboration") else null,
                ),
            )
        }
        return out
    }

    /// Turn canonical pooled torrent infohashes into playable [StreamSource]s. Every non-torrent or malformed
    /// row is dropped before it can enter the user's debrid pipeline. Mirrors Apple `streams(from:)`.
    fun streams(pooled: List<PooledSource>): List<StreamSource> {
        val built = pooled.take(MAX_SERVE_RESULTS).mapNotNull { src ->
            val kind = src.kind ?: return@mapNotNull null
            val id = src.id
            if (id.isNullOrEmpty()) return@mapNotNull null
            // Name/desc both say "Singularity" so the source ROW is visibly a Singularity source.
            if (kind == Kind.TORRENT.wire && (src.corroboration ?: 0) >= MIN_CORROBORATION
                && CANONICAL_INFOHASH.matches(id)) {
                makeTorrent("Other · Singularity", "Singularity source", id)
            } else {
                null
            }
        }
        Log.d(TAG, "streams reconstruct pooled=${pooled.size} -> playable=${built.size} (torrent-only)")
        return built
    }

    private fun makeTorrent(name: String, description: String, infoHash: String): StreamSource = StreamSource(
        id = "$infoHash#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        quality = "Other",
        isTorrent = true,
        infoHash = infoHash,
    )

    // MARK: - Feature gates

    /// Hard availability gate. Re-enable only after a separate lane wires and verifies six surfaces: consent,
    /// the SourceIndex fleet switch, VortX-account identity, X-VX-Moat token minting, exact baked-origin
    /// enforcement with every redirect refused, and bounded streamed GET/POST transport. Consent, fleet,
    /// account, and moat closure must cancel in-flight SERVE, clear current published sources, and prevent late
    /// publication before independent security sign-off. That lane must also relocate the
    /// non-evicting process ledger beside [uploadPacer], claim each paced <=16 batch immediately before POST,
    /// and verify cancellation plus overlapping callers.
    const val isEnabled: Boolean = false

    /// The per-user SERVE opt-in (the "Singularity" Settings toggle). Default ON (give-to-get; still sign-in
    /// gated in [fetchPooled]). A settings surface can flip this when one lands. Mirrors Apple `serveEnabled`.
    @Volatile
    var serveEnabled: Boolean = true

    /// Reserved hook for the future signed-off identity lane. It is never invoked while [isEnabled] is false.
    @Volatile
    var moatTokenProvider: (suspend () -> String?)? = null

    // MARK: - Singularity source-group identity (shared by the source list + the assembly)

    /// The stable group id [SourceIndexServeSource.merge] stamps on Singularity's merged group. Mirrors Apple
    /// `groupID`.
    const val GROUP_ID = "vortx.singularity.sources"

    /// The user-facing label on Singularity's source group + rows. Mirrors Apple `groupAddon`.
    const val GROUP_ADDON = "Singularity"

    // MARK: - Helpers

    private const val BASE_URL = "https://sources.vortx.tv"
    private const val HTTP_TIMEOUT_MS = 8_000
    private const val MOAT_HEADER = "X-VX-Moat"
    private const val MAX_SAFE_SIZE_BYTES = 9_007_199_254_740_991L
    private const val MAX_SEEDERS = 1_000_000
    internal const val MAX_SERVE_RESULTS = 100
    private const val MIN_CORROBORATION = 2

    /// Exact public title-id boundary shared by HOARD and SERVE. ASCII digits are intentional.
    internal fun canonicalContentId(raw: String): String? = raw.takeIf(CANONICAL_CONTENT_ID::matches)

    /// Pure SERVE request builder. Keeping validation here makes the no-network-on-invalid-id guarantee
    /// deterministic in local tests and prevents future callers from interpolating an unchecked id.
    internal fun serveUrl(contentId: String): String? {
        val canonical = canonicalContentId(contentId) ?: return null
        return "$BASE_URL/sources?content_id=${enc(canonical)}&kind=${Kind.TORRENT.wire}"
    }

    private fun normalizeInfoHash(raw: String?): String? {
        val normalized = raw?.lowercase() ?: return null
        return normalized.takeIf(CANONICAL_INFOHASH::matches)
    }

    private fun normalizeQuality(raw: String): String = when (raw.trim().lowercase()) {
        "4k", "2160p", "uhd" -> "4K"
        "1440p" -> "1440p"
        "1080p" -> "1080p"
        "720p" -> "720p"
        "576p" -> "576p"
        "540p" -> "540p"
        "480p", "sd" -> "480p"
        else -> "Other"
    }

    /// The overall per-title cap on descriptors uploaded. At [BATCH_SIZE] per POST this is at most 125 POSTs.
    internal const val MAX_DESCRIPTORS_PER_TITLE = 2000

    /// Sixteen descriptors produce 49 D1 statements (3 each plus one retention prune), under Cloudflare D1's
    /// 50-query Free-plan invocation limit. Keep this equal to the worker and Apple maximum.
    internal const val BATCH_SIZE = 16

    /// Delay between sequential batch POST starts. Just over one second keeps each process near 55/minute,
    /// leaving headroom within the worker's 240/minute per-IP limit for several devices behind one NAT.
    private const val INTER_BATCH_DELAY_MS = 1_100L

    /// One process-wide pacer, not one delay loop per title. This is the actual per-IP rate-control boundary.
    private val uploadPacer = SourceUploadPacer(INTER_BATCH_DELAY_MS)

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}

/// Serializes outbound actions and leaves [intervalMs] after the previous action completes. Clock and sleeper
/// injection make cross-invocation pacing deterministic to test without a real 1.1-second wait.
internal class SourceUploadPacer(
    private val intervalMs: Long,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000L },
    private val sleepMs: suspend (Long) -> Unit = { delay(it) },
) {
    private val mutex = Mutex()
    private var lastCompletedAtMs: Long? = null

    suspend fun <T> pace(action: suspend () -> T): T {
        mutex.lock()
        try {
            val previous = lastCompletedAtMs
            if (previous != null) {
                val remaining = intervalMs - (nowMs() - previous)
                if (remaining > 0) sleepMs(remaining)
            }
            return action()
        } finally {
            lastCompletedAtMs = nowMs()
            mutex.unlock()
        }
    }
}

/// A per-detail-view SERVE contributor that reads the community source index for the current title and
/// publishes the corroborated, actionable sources as one extra group to MERGE into the list. The Kotlin port
/// of Apple `SourceIndexServeSource`: `@Published streams` becomes a [StateFlow], the SwiftUI `Task` becomes a
/// coroutine [Job]. Completed results are never retained across instances. Gated inside [SourceIndexClient]
/// (toggle OFF / signed-out / fleet-off all yield an empty group).
class SourceIndexServeSource(
    /// The scope the fetch coroutines run on. Owned + cancellable via [close]; defaults to an IO scope so a
    /// caller that never provides one still works standalone.
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val _streams = MutableStateFlow<List<StreamSource>>(emptyList())

    /// The corroborated community streams, ready to merge. Empty until a fetch completes (and always when the
    /// SERVE toggle is off / signed out). Mirrors Apple's `@Published streams`.
    val streams: StateFlow<List<StreamSource>> = _streams.asStateFlow()

    private val epochCounter = AtomicInteger(0)

    /// Monotonic epoch bumped whenever [streams] is REPLACED. Folded into [com.vortx.android.engine.SourceListModel]'s
    /// rebuild signature. Mirrors the Apple `epoch`.
    val epoch: Int get() = epochCounter.get()

    private var lastContentId: String? = null
    private var job: Job? = null

    /// Fetch pooled sources for [contentId] when SERVE is enabled + the user is signed in. Fail-soft + deduped
    /// by content id. Safe to call on every meta change. Mirrors Apple `refresh`.
    fun refresh(contentId: String?, isSignedIn: Boolean) {
        val gateOpen = SourceIndexClient.serveEnabled && SourceIndexClient.isEnabled && isSignedIn
        val canonicalContentId = contentId?.let(SourceIndexClient::canonicalContentId)
        if (!gateOpen || canonicalContentId == null || canonicalContentId == lastContentId) {
            // Clear any previously-merged community sources whenever the SERVE gate is CLOSED, so stale rows do
            // not linger after the gate closes. A skip for an unchanged / null content id with the gate still
            // open leaves them in place.
            if (!gateOpen) {
                job?.cancel()
                job = null
                lastContentId = null
                if (_streams.value.isNotEmpty()) publish(emptyList())
            }
            return
        }
        lastContentId = canonicalContentId
        job?.cancel()
        job = scope.launch {
            val pooled = SourceIndexClient.fetchPooled(canonicalContentId, isSignedIn)
            val built = SourceIndexClient.streams(pooled)
            if (!isActive) {
                Log.d(TAG, "refresh publish SKIPPED contentId=$canonicalContentId (cancelled) built=${built.size}")
                return@launch
            }
            Log.d(TAG, "refresh publish contentId=$canonicalContentId streams=${built.size} (now merge-ready)")
            publish(built)
        }
    }

    /// Empty the published community streams and cancel any in-flight fetch. No completed result survives this
    /// instance, and [lastContentId] resets so a later refresh for the same title performs a fresh read.
    fun clearResults() {
        job?.cancel()
        lastContentId = null
        if (_streams.value.isNotEmpty()) publish(emptyList())
    }

    /// Cancel any in-flight fetch and tear down the owned scope. Call when the owning screen goes away.
    fun close() {
        job?.cancel()
        scope.coroutineContext[Job]?.cancel()
    }

    /// Merge the community sources into [groups] as its OWN named "Singularity" group, exactly like any other
    /// add-on. Mirrors Apple `merged(into:)`.
    fun merged(into: List<StreamGroup>): List<StreamGroup> = merge(_streams.value, into)

    private fun publish(value: List<StreamSource>) {
        _streams.value = value
        epochCounter.incrementAndGet()
    }

    companion object {
        private const val TAG = "sing"

        /// The pure merge: append canonical torrent sources as one "Singularity" group, deduped ONLY within its
        /// own list by infohash, NOT against the user's add-on groups. Mirrors Apple
        /// `SourceIndexServeSource.merge`.
        fun merge(extra: List<StreamSource>, groups: List<StreamGroup>): List<StreamGroup> {
            if (extra.isEmpty()) return groups
            val seen = HashSet<String>()
            val own = ArrayList<StreamSource>()
            for (s in extra) {
                val hash = s.infoHash ?: continue
                if (!CANONICAL_INFOHASH.matches(hash)) continue
                val key = "t:$hash"
                if (seen.add(key)) own.add(s)
            }
            if (own.isEmpty()) return groups
            return groups + StreamGroup(addon = SourceIndexClient.GROUP_ADDON, streams = own)
        }
    }
}
