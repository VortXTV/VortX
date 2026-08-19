package com.vortx.android.player.warm

import android.content.Context
import android.util.Log
import com.vortx.android.data.CatalogRepository
import com.vortx.android.engine.StreamRanking
import com.vortx.android.model.MediaType
import com.vortx.android.model.StreamGroup
import com.vortx.android.model.StreamSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.coroutineContext

/**
 * WARM-THE-PICK-ON-FOCUS. Given a title's ranked sources, resolve which one WOULD play (the same
 * [StreamRanking] the app uses), and warm the connection to it ahead of the tap: open the socket
 * (DNS + TCP + TLS), fetch the container HEADER, and touch the seek index at the tail, so when the viewer
 * hits play the first byte and the moov/index are already hot and the player starts faster.
 *
 * HARD RULE: direct / HTTP sources ONLY. A DEBRID (or torrent / usenet) source is NEVER resolved on mere
 * focus, because resolving hits a debrid account's unlock API (fair-use, one-time links) or the streaming
 * server. This warmer only ever touches a source that ALREADY carries a directly-playable http(s) URL and
 * is not a debrid-hosted link, so nothing is "resolved" and no account is charged. See [warmTargetUrl].
 *
 * SNAPSHOT / STALENESS GATE: every warm carries a monotonic generation; a newer focus supersedes an older
 * one (its in-flight reads see the generation move and stop), and a per-key staleness window keeps a
 * re-focus from re-warming the same pick. All work runs on [scope] (IO + SupervisorJob), never on a
 * caller's thread, and every failure is swallowed: a warm is a best-effort head start, never a dependency.
 */
object SourceWarmer {

    private const val TAG = "VortxSourceWarmer"

    /** Bytes of the container header to pull (front range). Enough to open the demuxer's moov/ebml probe. */
    private const val HEADER_BYTES = 512 * 1024

    /** Bytes of the tail (suffix range) to touch, warming an MP4 `moov` that sits at EOF (the seek index). */
    private const val TAIL_BYTES = 256 * 1024

    /** Cap on bytes actually read per range, so a warm never turns into a download. */
    private const val MAX_READ_PER_RANGE = 512 * 1024

    private const val CONNECT_TIMEOUT_MS = 8_000
    private const val READ_TIMEOUT_MS = 8_000
    private const val READ_CHUNK = 32 * 1024

    /** A pick warmed within this window is not re-warmed on a re-focus. */
    private const val WARM_STALE_MS = 5L * 60 * 1000

    /**
     * Known debrid host fragments. A source whose URL host contains one of these is treated as debrid and
     * never warmed (belt-and-suspenders on top of the structural torrent/usenet exclusion), since a debrid
     * CDN hit can consume a one-time link. Matched as a lowercase substring of the host.
     */
    private val DEBRID_HOST_FRAGMENTS = listOf(
        "real-debrid", "rdeb", "alldebrid", "premiumize", "torbox", "debrid-link", "debrid",
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val generation = AtomicLong(0)
    private val warmedAt = ConcurrentHashMap<String, Long>()

    /**
     * Warm the ranked pick from ALREADY-LOADED [groups] (the detail-open path: the streams are in memory,
     * so no engine re-entry is needed). [key] identifies the play target (content or episode id) for the
     * staleness gate. No-op when the pick is not a direct/HTTP source.
     */
    fun warmFromGroups(context: Context, groups: List<StreamGroup>, key: String) {
        if (!FocusPrefetchSetting.isEnabled(context)) return
        val gen = generation.incrementAndGet()
        if (isFresh(key)) return
        val target = pickWarmUrl(groups) ?: return
        launchWarm(target, key, gen)
    }

    /**
     * Warm the ranked pick for a Continue-Watching MOVIE on home focus-dwell. Loads the source groups via
     * [repo] (source ASSEMBLY only, which is not a debrid unlock), ranks them, and warms the direct winner.
     * MOVIE only: a series Continue-Watching card does not carry its resume episode id, so its correct
     * source cannot be ranked from the card alone (documented gap). [key] gates staleness; the generation
     * supersede means only the last-settled card actually warms.
     */
    fun warmForContinueWatching(
        context: Context,
        repo: CatalogRepository,
        type: MediaType,
        id: String,
    ) {
        if (!FocusPrefetchSetting.isEnabled(context)) return
        if (type != MediaType.MOVIE) return // series lacks a resume episode id on the CW card
        val key = "cw:${type.id}:$id"
        val gen = generation.incrementAndGet()
        if (isFresh(key)) return
        val appContext = context.applicationContext
        scope.launch {
            try {
                if (gen != generation.get()) return@launch
                val groups = repo.streams(type, id).getOrNull() ?: return@launch
                if (gen != generation.get()) return@launch
                val target = pickWarmUrl(groups) ?: return@launch
                warm(appContext, target, key, gen)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
                // Fail-soft: a missed warm just means the normal source search runs on tap, as before.
            }
        }
    }

    // ---- internals ----

    private fun launchWarm(url: String, key: String, gen: Long) {
        scope.launch {
            try {
                warm(null, url, key, gen)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Throwable) {
            }
        }
    }

    /** The direct/HTTP URL of the ranked winner, or null when the pick is not warm-eligible. */
    private fun pickWarmUrl(groups: List<StreamGroup>): String? {
        val best = runCatching { StreamRanking.best(groups) }.getOrNull() ?: return null
        return warmTargetUrl(best)
    }

    /**
     * The URL to warm for [source], or null when it must not be warmed. Eligible ONLY when the source
     * already carries a direct http(s) URL and is not a torrent / usenet / YouTube-trailer source and its
     * host is not a known debrid host. A media-server direct-play source is always eligible (it is the
     * viewer's own box). Pure, so the policy is unit-testable.
     */
    internal fun warmTargetUrl(source: StreamSource): String? {
        val url = source.url ?: return null
        if (!url.startsWith("http://", true) && !url.startsWith("https://", true)) return null
        if (source.isTorrent || source.isUsenet || source.isYouTubeTrailer) return null
        if (source.isMediaServer) return url
        val host = runCatching { URL(url).host?.lowercase() }.getOrNull() ?: return null
        if (DEBRID_HOST_FRAGMENTS.any { host.contains(it) }) return null
        return url
    }

    private fun isFresh(key: String): Boolean {
        val at = warmedAt[key] ?: return false
        return System.currentTimeMillis() - at <= WARM_STALE_MS
    }

    /** Open the socket, pull the header range and the tail range, then mark [key] warmed. Best-effort. */
    private suspend fun warm(context: Context?, url: String, key: String, gen: Long) = withContext(Dispatchers.IO) {
        if (gen != generation.get()) return@withContext
        val headerOk = drainRange(url, "bytes=0-${HEADER_BYTES - 1}", gen)
        if (gen != generation.get()) return@withContext
        // Only bother with the tail once the header connection succeeded (a dead link fails fast on header).
        if (headerOk) drainRange(url, "bytes=-$TAIL_BYTES", gen)
        warmedAt[key] = System.currentTimeMillis()
        context?.hashCode() // keep the optional context reference meaningful without leaking it
        Log.i(TAG, "warmed pick for $key (header=$headerOk) host=${runCatching { URL(url).host }.getOrNull()}")
    }

    /** GET [range] with finite timeouts, read a bounded prefix, discard. Returns whether a 2xx/3xx opened. */
    private suspend fun drainRange(url: String, range: String, gen: Long): Boolean {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("Range", range)
        }
        return try {
            val code = conn.responseCode
            if (code !in 200..299) return false
            val buf = ByteArray(READ_CHUNK)
            conn.inputStream.use { input ->
                var total = 0
                while (total < MAX_READ_PER_RANGE) {
                    coroutineContext.ensureActive()
                    if (gen != generation.get()) break
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                }
            }
            true
        } catch (e: CancellationException) {
            runCatching { conn.disconnect() }
            throw e
        } catch (_: Throwable) {
            false
        } finally {
            runCatching { conn.disconnect() }
        }
    }
}

/**
 * Kill switch for the warm-the-pick-on-focus prefetch (detail-open + Continue-Watching focus warmers).
 * DEFAULT ON. Flipping it off restores the pre-warm behavior (the pick is only resolved on tap). Stored in
 * the shared `vortx_settings` file, flippable like the other player kill switches. Warming only ever
 * touches direct/HTTP sources (never debrid), so this gate is about network eagerness, not correctness.
 */
object FocusPrefetchSetting {
    const val KEY = "vortx.player.focusPrefetch"
    const val DEFAULT = true

    private const val SETTINGS_FILE = "vortx_settings"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, DEFAULT)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}
