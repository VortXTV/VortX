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
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicInteger

/// Client for VortX's community SOURCE INDEX at `sources.vortx.tv` ("Singularity"): the Kotlin port of Apple
/// `app/SourcesShared/SourceIndexClient.swift`. The pooled record of which SOURCES (torrent / usenet / direct)
/// exist for a title, corroborated across users.
///
/// TWO halves, both fully fail-soft (any miss / error / offline is a silent no-op; nothing ever blocks or
/// slows playback or a screen):
///
///   1. HOARD (default ON, anonymous): whenever the app assembles a title's stream results, it reports the
///      source DESCRIPTORS, NOT the media, NOT any account token or user id. A descriptor is only
///      { kind, id, quality, sizeBytes, sourceTag, seeders? } where `id` is the source's real, re-resolvable
///      identity: a torrent infohash, a usenet nzb link, or the direct http link. The worker STRIPS credential
///      query params before storing. Fire-and-forget, batched, deduped by id.
///
///   2. SERVE (opt-in): when the user turns the Singularity toggle ON AND is signed in, the detail screen
///      reads the corroborated pooled sources and MERGES them into the stream list, ALL kinds (torrent /
///      usenet / direct), each resolved by the user's own debrid / TorBox pipeline. Empty on any miss;
///      signed-out disables the read entirely (hard login gate, matching the worker).
///
/// GATING (VortX-only): `sources.vortx.tv` is a [VortXEdgeAuth] gated host, so BOTH the POST and the GET are
/// HMAC-signed. Signing is a safe no-op without a provisioned secret (the worker's observe mode allows it).
///
/// PARITY GAPS (Android has no surface yet, documented like [com.vortx.android.trickplay.CommunityTrickplay]):
///   - The `MoatConsent.contributeAndConsume` give-to-get toggle and the RemoteConfig `sourceIndex` fleet
///     kill-switch are absent, so [isEnabled] is a plain feature-on default; wire them here when they land.
///   - The SERVE X-VX-Moat token (Apple stamps `MoatToken` after the edge signature; the worker returns an
///     empty list without it) has no Android surface, so [moatTokenProvider] defaults to a null hook. Until it
///     is wired, SERVE reads sign as observe-mode requests and the worker returns empty under moat enforce.
object SourceIndexClient {

    private const val TAG = "sing"

    // MARK: - Public models

    /// A source kind as the pool records it. Mirrors the app's torrent / usenet / direct classification.
    enum class Kind(val wire: String) { TORRENT("torrent"), USENET("usenet"), DIRECT("direct") }

    /// One anonymized source descriptor for the HOARD upload. Carries ONLY public, non-personal fields.
    /// Mirrors Apple `Descriptor`.
    data class Descriptor(
        val kind: String,
        val id: String, // infohash (torrent) | real nzb link (usenet) | real http link (direct)
        val quality: String, // e.g. "4K", "1080p", "Other" (from StreamRanking.qualityLabel)
        val sizeBytes: Long, // 0 when the add-on advertised no size
        val sourceTag: String, // the add-on / provider label the source came from (no user data)
        val seeders: Int?, // torrents only, when advertised
    )

    /// One corroborated source the pool returns for SERVE. `id` matches the descriptor id space. Mirrors
    /// Apple `PooledSource`.
    data class PooledSource(
        val kind: String?,
        val id: String?,
        val quality: String?,
        val sizeBytes: Long?,
        val sourceTag: String?,
        val seeders: Int?,
        val corroboration: Int?,
    )

    // MARK: - Content id (colon form: imdb[:season:episode])

    /// The pool `content_id` for a title, in the worker's colon form (`tt0903747` for a movie, `tt…:S:E` for an
    /// episode). null when the id is not a real imdb `tt…` id. Mirrors Apple `contentID`.
    fun contentId(imdbId: String?, season: Int? = null, episode: Int? = null): String? {
        if (imdbId == null) return null
        val match = Regex("""^tt\d{6,}""").find(imdbId) ?: return null
        val base = match.value
        return if (season != null && episode != null) "$base:$season:$episode" else base
    }

    // MARK: - Descriptor extraction (pure; no user data)

    /// Build the anonymized descriptor set for a title's assembled source groups. Uses [StreamRanking] as the
    /// single source of truth for quality / size / seeders, so the pool's view matches the app's. Skips
    /// YouTube trailers and any stream with no derivable public id. Deduped by descriptor id. Mirrors Apple
    /// `descriptors(from:)`.
    fun descriptors(groups: List<StreamGroup>): List<Descriptor> {
        val seen = HashSet<String>()
        val out = ArrayList<Descriptor>()
        for (group in groups) {
            for (stream in group.streams) {
                if (stream.isYouTubeTrailer) continue
                val d = descriptor(stream, group.addon) ?: continue
                if (seen.add(d.kind + "|" + d.id)) out.add(d)
            }
        }
        return out
    }

    /// One descriptor for one stream, or null when it carries no public identity. The debrid-resolved `url` of
    /// a torrent is a PERSONAL link, so it is never sent (the public infohash is used instead). Mirrors Apple
    /// `descriptor(for:sourceTag:)`.
    private fun descriptor(stream: StreamSource, sourceTag: String): Descriptor? {
        val sizeGb = StreamRanking.sizeForSort(stream) // GB (0 when unknown)
        val sizeBytes = if (sizeGb > 0) Math.round(sizeGb * 1024.0 * 1024.0 * 1024.0) else 0L
        val quality = StreamRanking.qualityLabel(stream)
        val tag = sanitizeTag(sourceTag)

        // USENET: keyed by the REAL nzb link so any user can re-resolve it with their own TorBox usenet plan.
        val nzb = stream.nzbUrl
        if (stream.isUsenet && !nzb.isNullOrEmpty()) {
            return Descriptor(Kind.USENET.wire, nzb, quality, sizeBytes, tag, seeders = null)
        }
        // TORRENT (raw OR debrid-resolved): keyed by the infohash, which is public and identity-stable. The
        // (possibly personal) resolved url is never sent.
        val hash = stream.infoHash?.lowercase()
        if (!hash.isNullOrEmpty()) {
            val seeders = StreamRanking.seedersForSort(stream)
            return Descriptor(Kind.TORRENT.wire, hash, quality, sizeBytes, tag, seeders = if (seeders >= 0) seeders else null)
        }
        // DIRECT: a plain http(s) link with no infohash. Keyed by the REAL link (credential params stripped
        // worker-side) so another user can play it or unrestrict it through their own debrid.
        val url = stream.url
        if (!url.isNullOrEmpty()) {
            return Descriptor(Kind.DIRECT.wire, url, quality, sizeBytes, tag, seeders = null)
        }
        return null
    }

    // MARK: - HOARD: POST /sources/contribute (signed, fire-and-forget)

    /// Report the assembled source descriptors for a title. Gated on the feature flag. Popular titles resolve
    /// far more than one POST can carry (the worker truncates at MAX_SOURCES_PER_CONTRIBUTE = 100), so we chunk
    /// the whole deduped set into [BATCH_SIZE]-descriptor POSTs sent SEQUENTIALLY, spaced by
    /// [INTER_BATCH_DELAY_MS] to stay under the worker's per-IP rate limit. Each POST is independently
    /// fire-and-forget. No-op on an empty set. Mirrors Apple `contribute`.
    suspend fun contribute(contentId: String, descriptors: List<Descriptor>) {
        if (!isEnabled || descriptors.isEmpty()) return
        val all = descriptors.take(MAX_DESCRIPTORS_PER_TITLE)
        val batches = all.chunked(BATCH_SIZE)
        withContext(Dispatchers.IO) {
            for ((i, chunk) in batches.withIndex()) {
                if (!isActive) return@withContext
                postBatch(contentId, chunk, i + 1, batches.size)
                // Space the batches so the whole run stays under the worker per-IP limit. Skip after the last.
                if (i < batches.size - 1) delay(INTER_BATCH_DELAY_MS)
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
        val body = JSONObject().apply {
            put("content_id", contentId)
            val arr = JSONArray()
            for (d in chunk) {
                arr.put(
                    JSONObject().apply {
                        put("kind", d.kind)
                        put("id", d.id)
                        put("quality", d.quality)
                        put("sizeBytes", d.sizeBytes)
                        put("sourceTag", d.sourceTag)
                        if (d.seeders != null) put("seeders", d.seeders)
                    },
                )
            }
            put("sources", arr)
        }.toString()

        var conn: HttpURLConnection? = null
        try {
            conn = (URL("$BASE_URL/sources/contribute").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = HTTP_TIMEOUT_MS
                readTimeout = HTTP_TIMEOUT_MS
                useCaches = false
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

    // MARK: - SERVE: GET /sources?content_id=… (signed, opt-in + login-gated)

    /// Read the corroborated pooled sources for [contentId]. Returns `[]` unless the Singularity SERVE toggle
    /// is on AND the user is signed in AND the fleet flag is on. Fail-soft to `[]` on any error or when
    /// disabled. Mirrors Apple `fetchPooled`.
    suspend fun fetchPooled(contentId: String, isSignedIn: Boolean): List<PooledSource> {
        Log.d(TAG, "fetchPooled GATE contentId=$contentId isEnabled=$isEnabled serveEnabled=$serveEnabled isSignedIn=$isSignedIn")
        if (!isEnabled || !serveEnabled || !isSignedIn) {
            Log.d(TAG, "fetchPooled GATE CLOSED contentId=$contentId -> [] (gate off / not signed in)")
            return emptyList()
        }
        val moat = runCatching { moatTokenProvider?.invoke() }.getOrNull()
        return withContext(Dispatchers.IO) {
            val url = "$BASE_URL/sources?content_id=${enc(contentId)}"
            var conn: HttpURLConnection? = null
            try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = HTTP_TIMEOUT_MS
                    readTimeout = HTTP_TIMEOUT_MS
                    useCaches = false
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

    private fun parsePooled(body: String): List<PooledSource> {
        val root = runCatching { JSONObject(body) }.getOrNull() ?: return emptyList()
        val arr = root.optJSONArray("sources") ?: return emptyList()
        val out = ArrayList<PooledSource>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(
                PooledSource(
                    kind = o.optStringOrNull("kind"),
                    id = o.optStringOrNull("id"),
                    quality = o.optStringOrNull("quality"),
                    sizeBytes = if (o.has("sizeBytes") && !o.isNull("sizeBytes")) o.optLong("sizeBytes") else null,
                    sourceTag = o.optStringOrNull("sourceTag"),
                    seeders = if (o.has("seeders") && !o.isNull("seeders")) o.optInt("seeders") else null,
                    corroboration = if (o.has("corroboration") && !o.isNull("corroboration")) o.optInt("corroboration") else null,
                ),
            )
        }
        return out
    }

    /// Turn the corroborated pooled sources into playable [StreamSource]s to merge. ALL three kinds are
    /// reconstructable: a torrent (infohash id), a usenet source (real nzb link id), and a direct source (real
    /// http link id), each then resolved by the user's own debrid / TorBox pipeline. A LEGACY row whose id is
    /// a bare hash (old fleet stored sha256 for usenet/http) is not replayable and is dropped. Mirrors Apple
    /// `streams(from:)`.
    fun streams(pooled: List<PooledSource>): List<StreamSource> {
        val built = pooled.mapNotNull { src ->
            val kind = src.kind ?: return@mapNotNull null
            val id = src.id
            if (id.isNullOrEmpty()) return@mapNotNull null
            val quality = src.quality?.takeIf { it.isNotEmpty() } ?: "Source"
            val sizeSuffix = if ((src.sizeBytes ?: 0) > 0) " · ${humanSize(src.sizeBytes ?: 0)}" else ""
            val seedSuffix = src.seeders?.let { " · 👤 $it" }.orEmpty()
            // Name/desc both say "Singularity" so the source ROW is visibly a Singularity source.
            val name = "$quality · Singularity"
            val isLink = id.lowercase().startsWith("http://") || id.lowercase().startsWith("https://")
            when (kind) {
                Kind.TORRENT.wire -> {
                    if (Regex("""^[0-9a-fA-F]{20,64}$""").matches(id)) {
                        makeTorrent(name, "Singularity source$sizeSuffix$seedSuffix", id.lowercase())
                    } else {
                        null
                    }
                }
                Kind.USENET.wire -> if (isLink) makeUsenet(name, "Singularity usenet$sizeSuffix", id) else null
                "http", Kind.DIRECT.wire -> if (isLink) makeDirect(name, "Singularity source$sizeSuffix", id) else null
                else -> null
            }
        }
        Log.d(TAG, "streams reconstruct pooled=${pooled.size} -> playable=${built.size} (legacy-hash rows dropped)")
        return built
    }

    private fun makeTorrent(name: String, description: String, infoHash: String): StreamSource = StreamSource(
        id = "$infoHash#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        isTorrent = true,
        infoHash = infoHash,
    )

    private fun makeUsenet(name: String, description: String, nzbUrl: String): StreamSource = StreamSource(
        id = "$nzbUrl#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        nzbUrl = nzbUrl,
    )

    private fun makeDirect(name: String, description: String, url: String): StreamSource = StreamSource(
        id = "$url#$name#$description",
        addon = GROUP_ADDON,
        title = name,
        description = description,
        url = url,
    )

    // MARK: - Feature gates

    /// The master gate for the whole client. Apple ANDs give-to-get consent + the RemoteConfig fleet flag;
    /// Android has neither surface (see the class doc), so this is a plain feature-on default. Wire the consent
    /// + kill-switch here when they land, exactly as Apple's `isEnabled` does.
    const val isEnabled: Boolean = true

    /// The per-user SERVE opt-in (the "Singularity" Settings toggle). Default ON (give-to-get; still sign-in
    /// gated in [fetchPooled]). A settings surface can flip this when one lands. Mirrors Apple `serveEnabled`.
    @Volatile
    var serveEnabled: Boolean = true

    /// Optional hook that yields the short-lived X-VX-Moat token for a SERVE read (null = no surface wired
    /// yet). Set once a MoatToken surface exists on Android; until then SERVE signs as an observe-mode request.
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

    /// The overall per-title cap on descriptors uploaded. At [BATCH_SIZE] per POST this is at most 20 POSTs.
    private const val MAX_DESCRIPTORS_PER_TITLE = 2000

    /// Descriptors per POST. MUST stay <= the worker's MAX_SOURCES_PER_CONTRIBUTE (currently 100) or each batch
    /// tail is truncated worker-side and silently lost.
    private const val BATCH_SIZE = 100

    /// Delay between sequential batch POSTs, just over one second so 20 batches spread over ~21s stay under the
    /// worker's per-IP limit (60 contributes per 60s).
    private const val INTER_BATCH_DELAY_MS = 1_100L

    /// Trim + bound the source tag so it stays a short provider label with no accidental user data.
    private fun sanitizeTag(raw: String): String {
        val t = raw.trim()
        return if (t.isEmpty()) "Add-on" else t.take(64)
    }

    /// A binary byte size ("12.4 GB" / "850 MB") for the row detail line, locale-US so the decimal separator
    /// is always '.'.
    private fun humanSize(bytes: Long): String {
        if (bytes <= 0) return ""
        val gb = bytes / 1_073_741_824.0
        if (gb >= 1.0) return String.format(java.util.Locale.US, "%.1f GB", gb)
        val mb = bytes / 1_048_576.0
        if (mb >= 1.0) return String.format(java.util.Locale.US, "%.0f MB", mb)
        val kb = bytes / 1024.0
        return String.format(java.util.Locale.US, "%.0f KB", kb)
    }

    private fun JSONObject.optStringOrNull(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return optString(key).ifBlank { null }
    }

    private fun enc(value: String): String = URLEncoder.encode(value, "UTF-8")
}

/// A per-detail-view SERVE contributor that reads the community source index for the current title and
/// publishes the corroborated, actionable sources as one extra group to MERGE into the list. The Kotlin port
/// of Apple `SourceIndexServeSource`: `@Published streams` becomes a [StateFlow], the SwiftUI `Task` becomes a
/// coroutine [Job], and the process-lifetime result bank (the publish-lost fix) is preserved. Gated inside
/// [SourceIndexClient] (toggle OFF / signed-out / fleet-off all yield an empty group).
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
        if (!gateOpen || contentId == null || contentId == lastContentId) {
            // Clear any previously-merged community sources whenever the SERVE gate is CLOSED, so stale rows do
            // not linger after the gate closes. A skip for an unchanged / null content id with the gate still
            // open leaves them in place.
            if (!gateOpen && _streams.value.isNotEmpty()) publish(emptyList())
            return
        }
        lastContentId = contentId
        // WARM PAINT: a fetch for this exact content id already landed this process (often on a predecessor
        // view destroyed before the round trip returned). Publish it synchronously so the recreated view
        // merges the pool immediately; the network fetch below still runs and replaces it with the fresh
        // answer.
        bankedFor(contentId)?.let { banked ->
            if (banked.isNotEmpty()) {
                Log.d(TAG, "refresh seeded from bank contentId=$contentId streams=${banked.size}")
                publish(banked)
            }
        }
        job?.cancel()
        job = scope.launch {
            val pooled = SourceIndexClient.fetchPooled(contentId, isSignedIn)
            val built = SourceIndexClient.streams(pooled)
            // Bank BEFORE the liveness guard: the result is correct for this content id whether or not the
            // requesting view survived. Empty results are never banked (a young pool may fill; keep asking).
            if (built.isNotEmpty()) bank(contentId, built)
            if (!isActive) {
                Log.d(TAG, "refresh publish SKIPPED contentId=$contentId (cancelled) built=${built.size}")
                return@launch
            }
            Log.d(TAG, "refresh publish contentId=$contentId streams=${built.size} (now merge-ready)")
            publish(built)
        }
    }

    /// Empty the PUBLISHED community streams, cancelling any in-flight fetch first (its completion publishes
    /// unconditionally, so an uncancelled late answer for a previous title would repopulate after this clear).
    /// The cancel loses nothing durable: the fetch banks its result BEFORE the liveness guard. [lastContentId]
    /// resets so a later refresh for the SAME title re-publishes (bank-seeded). Mirrors Apple `clearResults`.
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

        // MARK: - Process-lifetime result bank (publish-lost fix)

        /// Last successfully BUILT pool result per content id, process-lifetime. The fetch result used to live
        /// only on the per-view instance, which is routinely destroyed before the ~0.5s network round trip
        /// returns (the "Singularity sources never appear" report). Banking by content id lets the NEXT
        /// instance for the same title publish instantly. Bounded defensively: on overflow it resets. Mirrors
        /// Apple's `resultBank`.
        private val resultBank = HashMap<String, List<StreamSource>>()

        private fun bank(contentId: String, built: List<StreamSource>) {
            synchronized(resultBank) {
                if (resultBank.size >= 64 && !resultBank.containsKey(contentId)) resultBank.clear()
                resultBank[contentId] = built
            }
        }

        /// The banked build for [contentId], or null. Serialized against concurrent [bank] writes.
        private fun bankedFor(contentId: String): List<StreamSource>? =
            synchronized(resultBank) { resultBank[contentId] }

        /// The pure merge: append the community sources as one "Singularity" group, deduped ONLY within its own
        /// list (by replayable identity: torrent infohash, usenet nzb link, or direct url), NOT against the
        /// user's add-on groups (so a release your add-ons already return still appears under the Singularity
        /// label). Mirrors Apple `SourceIndexServeSource.merge`.
        fun merge(extra: List<StreamSource>, groups: List<StreamGroup>): List<StreamGroup> {
            if (extra.isEmpty()) return groups
            val seen = HashSet<String>()
            val own = ArrayList<StreamSource>()
            for (s in extra) {
                val h = s.infoHash?.lowercase()
                val nzb = s.nzbUrl
                val u = s.url
                val key: String? = when {
                    !h.isNullOrEmpty() -> "t:$h"
                    !nzb.isNullOrEmpty() -> "u:$nzb"
                    !u.isNullOrEmpty() -> "d:$u"
                    else -> null
                }
                if (key == null) continue
                if (seen.add(key)) own.add(s)
            }
            if (own.isEmpty()) return groups
            return groups + StreamGroup(addon = SourceIndexClient.GROUP_ADDON, streams = own)
        }
    }
}
