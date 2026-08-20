package com.vortx.android.moat

import android.content.Context
import com.vortx.android.net.VortXEdgeAuth
import com.vortx.android.trickplay.TmdbImdbResolver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * Fleet WATCH SIGNAL: the anonymized "this fleet watched X today" ping that powers VortX's OWN
 * Trending / Popular / Most-Watched rows (a real ranking of its own rather than TMDB-only ordering). The
 * Kotlin port of Apple `app/SourcesShared/WatchSignalClient.swift`.
 *
 * Contract (matches the `watch.vortx.tv` worker, which is created + deployed separately and is owner-gated,
 * so this client MUST fail soft until it exists):
 *   POST https://watch.vortx.tv/ping   body: { "content_id": "tt1234567", "day": "2026-07-02", "type": "movie" }
 *   - content_id: the title's imdb `tt...` id (never a season / episode / tmdb id, so a series aggregates by show).
 *   - day: a UTC day bucket (YYYY-MM-DD), so the worker can dedup one witness per title/day.
 * The worker adds a daily-salted witness dedup of its own; NO user id / token / PII is ever sent from here.
 *
 * PRIVACY + GATING (give-to-get): every send is gated on [MoatConsent.contributeAndConsume] (the one master
 * pool switch) AND edge-auth signed ([VortXEdgeAuth], observe-safe). One ping per (content_id, day) PER DEVICE
 * is sent at most once: a local SharedPreferences set dedups so a long watch / re-open / episode-hop never
 * re-pings. Fully fail-soft: any miss / error / offline / not-yet-deployed worker leaves no trace and never
 * disturbs playback.
 *
 * Confidentiality: the user-facing framing is the generic anonymized-playback disclosure ([MoatConsent]); this
 * file's role in the ranking is never surfaced in any public artifact.
 */
object WatchSignalClient {

    /**
     * The watch-signal edge. Baked (not a RemoteConfig dial yet): the worker is owner-gated and created
     * separately; keep the host in sync with [VortXEdgeAuth] gated hosts (already lists watch.vortx.tv).
     */
    private const val BASE_URL = "https://watch.vortx.tv"

    /** The shared player-adjacent settings file, matching [MoatConsent] and CommunityTrickplay. */
    private const val SETTINGS_FILE = "vortx_settings"

    /**
     * SharedPreferences key holding the ordered "contentId|day" markers already pinged, so a device pings a
     * given title at most once per day. Byte-for-byte Apple's `stremiox.watchSignalSent`. Stored as a single
     * newline-joined string so insertion order is preserved and the oldest markers can be dropped when the set
     * exceeds [SENT_CAP], matching Apple's bounded array.
     */
    private const val SENT_KEY = "stremiox.watchSignalSent"
    private const val SENT_CAP = 500

    /**
     * SharedPreferences key for this install's stable, non-PII dedupe id sent in the `X-VX-Watcher` header,
     * byte-for-byte Apple's `stremiox.watchSignalWatcherId`. Minted once (a random UUID) and reused, so the
     * worker's per-device dedup is accurate instead of a coarse IP+UA fingerprint. Not tied to any account,
     * carries no PII, and the worker hashes it so the raw value is never persisted server-side.
     */
    private const val WATCHER_ID_KEY = "stremiox.watchSignalWatcherId"

    /** The per-device dedupe header the worker hashes; matches Apple `X-VX-Watcher`. */
    private const val WATCHER_HEADER = "X-VX-Watcher"

    private const val HTTP_TIMEOUT_MS = 12_000

    /** Only real imdb ids witness the pool. Matches Apple's `^tt\d{6,}$` guard (no upper bound). */
    private val TT_ID = Regex("""^tt\d{6,}$""")

    /** Process-lifetime fire-and-forget scope; mirrors Apple's detached background tasks. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** Serializes the read-modify-write of the marker set so concurrent 60s ticks can't double-send. */
    private val markerLock = Any()

    /**
     * Send ONE anonymized watch ping for [contentId] (an imdb `tt...` id) if pool consent is on and this title
     * has not already been pinged today from this device. Fire-and-forget + fully fail-soft. Mirrors Apple
     * `pingResolvingTMDB`.
     *
     * Call from the same ~60s "the user is really watching this" playback tick that auto-adds to the Library,
     * so a ping represents a real watch (not a hover / a mistaken open). Series pass the SHOW's `tt` id (via the
     * resolver) so the ranking aggregates by title, not by episode.
     *
     * [type] is the title's kind ("movie" / "series"); it is sent so the worker can group its rows by type. The
     * worker validates + lowercases it, so any non-conforming value is harmless.
     *
     * A `tmdb:...` library id (hub / TMDB-catalog play) is first resolved to its `tt...` identity so those
     * watches feed the pool too: a cached mapping pings inline; a cache miss kicks ONE background resolve and
     * pings when it lands (never blocking the playback tick). A non-tt, non-tmdb id is left to [ping]'s guard.
     */
    fun pingResolvingTmdb(context: Context, contentId: String, type: String, seriesHint: Boolean) {
        val appContext = context.applicationContext
        if (contentId.lowercase(Locale.US).startsWith("tmdb")) {
            val cached = TmdbImdbResolver.cachedImdbId(contentId)
            if (cached != null) {
                ping(appContext, cached, type)
            } else {
                scope.launch {
                    val tt = TmdbImdbResolver.resolveImdbId(appContext, contentId, seriesHint)
                    if (tt != null) ping(appContext, tt, type)
                }
            }
            return
        }
        ping(appContext, contentId, type) // tt id (or a non-tmdb id the guard below rejects)
    }

    /**
     * Send ONE ping for a resolved [contentId], gated + deduped. Mirrors Apple `ping`. The consent check, the
     * tt-only guard, and the atomic per-title/day claim all run BEFORE the request so a retry storm can never
     * double-send.
     */
    fun ping(context: Context, contentId: String, type: String) {
        val appContext = context.applicationContext
        // GIVE-TO-GET: no contribution without pool consent.
        if (!MoatConsent.contributeAndConsume(appContext)) return
        // Only real imdb ids witness the pool (a tmdb: / kitsu: / synthetic id is never a shareable identity).
        if (!TT_ID.matches(contentId)) return

        val day = dayBucket()
        val marker = "$contentId|$day"
        // Atomic claim: recorded BEFORE the request so a retry storm can't double-send; one ping per title/day.
        if (!claimMarker(appContext, marker)) return

        val watcher = watcherId(appContext)
        scope.launch {
            postPing(contentId, day, type, watcher)
        }
    }

    private fun postPing(contentId: String, day: String, type: String, watcher: String) {
        val body = JSONObject().apply {
            put("content_id", contentId)
            put("day", day)
            put("type", type)
        }.toString()

        var conn: HttpURLConnection? = null
        try {
            conn = (URL("$BASE_URL/ping").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = HTTP_TIMEOUT_MS
                readTimeout = HTTP_TIMEOUT_MS
                useCaches = false
                instanceFollowRedirects = false
                doOutput = true
                setRequestProperty("content-type", "application/json")
                setRequestProperty(WATCHER_HEADER, watcher) // per-device dedupe (hashed worker-side; no PII)
            }
            VortXEdgeAuth.sign(conn) // gated host (watch.vortx.tv): stamp X-VX-Ts / X-VX-Kid / X-VX-Sig
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            // Fail-soft: the worker may not be deployed yet (owner-gated). Any error / non-200 is swallowed; the
            // local marker already prevents a re-send today, and tomorrow's bucket retries naturally.
            conn.responseCode
        } catch (_: Throwable) {
            // fire-and-forget: any failure leaves no trace and never disturbs playback
        } finally {
            conn?.disconnect()
        }
    }

    // MARK: - Local per-day dedup + watcher id

    /**
     * Atomically claim [marker]: returns true and records it if it was not already present, false if a prior
     * tick already claimed it. The whole check-and-record runs under [markerLock]. Mirrors Apple `claimMarker`.
     */
    private fun claimMarker(context: Context, marker: String): Boolean {
        synchronized(markerLock) {
            val prefs = context.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
            val current = decodeMarkers(prefs.getString(SENT_KEY, null))
            val (claimed, next) = claimMarkerIn(current, marker, SENT_CAP)
            if (!claimed) return false
            prefs.edit().putString(SENT_KEY, encodeMarkers(next)).apply()
            return true
        }
    }

    /**
     * The stable per-install watcher id, minted lazily on first use and reused forever after. An opaque random
     * UUID (non-PII); the worker only ever stores its hash. Mirrors Apple `watcherId`.
     */
    private fun watcherId(context: Context): String {
        val prefs = context.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
        val existing = prefs.getString(WATCHER_ID_KEY, null)
        if (!existing.isNullOrEmpty()) return existing
        val fresh = UUID.randomUUID().toString()
        prefs.edit().putString(WATCHER_ID_KEY, fresh).apply()
        return fresh
    }

    // MARK: - Pure helpers (kept side-effect-free for deterministic tests)

    /**
     * Pure atomic-claim logic over the ordered marker list: returns (false, unchanged) when [marker] is already
     * present, else (true, appended-and-bounded). When the list exceeds [cap] the oldest markers are dropped,
     * matching Apple's `removeFirst(count - cap)`.
     */
    internal fun claimMarkerIn(existing: List<String>, marker: String, cap: Int): Pair<Boolean, List<String>> {
        if (existing.contains(marker)) return false to existing
        val appended = existing + marker
        val bounded = if (appended.size > cap) appended.subList(appended.size - cap, appended.size) else appended
        return true to bounded
    }

    /** UTC day bucket for [date] as YYYY-MM-DD, so the whole fleet buckets on the same boundary as the worker. */
    internal fun dayBucket(date: Date = Date()): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(date)
    }

    /** Whether [contentId] is a poolable imdb id (matches Apple's tt-only witness guard). */
    internal fun isPoolableId(contentId: String): Boolean = TT_ID.matches(contentId)

    private fun decodeMarkers(raw: String?): List<String> =
        raw?.split('\n')?.filter { it.isNotEmpty() } ?: emptyList()

    private fun encodeMarkers(markers: List<String>): String = markers.joinToString("\n")
}
