package com.vortx.android.player.tuning

import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import com.vortx.android.player.BufferTuningSetting
import com.vortx.android.player.DeviceMemoryTier
import com.vortx.android.player.DiskCacheSetting
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The facade that ties the adaptive-tuning pieces together and is read at the two engine construction
 * sites (ExoPlayer LoadControl, mpv demuxer config). It layers ON TOP of the merged RAM-tier ladder,
 * never replacing it: the RAM tier is the ceiling, [BufferIntentProfile] and the measured link speed
 * decide where inside it to sit.
 *
 * Responsibilities:
 *   - [currentPlan]: the [AdaptiveBufferPlan] for right now (RAM tier + intent + freshest link sweep).
 *   - [mpvRemoteReadAheadBytes]: mpv's per-file `demuxer-max-bytes` on the capable remote path, the
 *     RAM-tier value scaled by the plan fraction, then clamped by free disk and floored (the same floor +
 *     clamp the merged code used), so the merged behavior is the BALANCED-with-no-link case exactly.
 *   - [initialBitrateEstimate]: seed for ExoPlayer's bandwidth meter, from the measured link when known.
 *   - [noteStream]: record the just-loaded stream and, when opted in and on an unmetered link, kick a
 *     BACKGROUND link sweep against it so the NEXT play has a real measurement. Fail-soft and gated.
 *
 * All network work runs on [scope] (IO + SupervisorJob), never on a caller's thread, and a single
 * in-flight guard plus a per-host staleness window keep it from hammering a CDN.
 */
object AdaptiveTuning {

    private const val TAG = "VortxAdaptiveTuning"
    private const val BYTES_PER_MB = 1024L * 1024

    /** mpv remote read-ahead floor: never below the merged conservative flat cap (128 MiB). */
    private const val MPV_REMOTE_FLOOR_BYTES = 128L * 1024 * 1024

    /** A cached link measurement is stale after this long; a stream on a stale host re-probes. */
    private const val PROBE_STALE_MS = 10L * 60 * 1000

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val probing = AtomicBoolean(false)

    private data class Cached(val result: LinkSpeedProbe.Result, val atMs: Long)

    /** host -> freshest measurement. Small and self-evicting via the staleness check on read. */
    private val probeByHost = ConcurrentHashMap<String, Cached>()

    @Volatile
    private var lastStreamHost: String = ""

    /** The full adaptive plan for the current device, intent, and freshest link sweep. */
    fun currentPlan(context: Context): AdaptiveBufferPlan {
        val ramBudget = ramBudgetBytes(context)
        val intent = BufferIntentProfile.current(context)
        return AdaptiveBufferPlanner.plan(ramBudget, freshestLinkBps(), intent)
    }

    /**
     * mpv's per-file forward read-ahead (bytes) on the capable remote path. The RAM-tier budget scaled by
     * the plan fraction, clamped to half of CURRENT free disk (as the merged code did), floored at
     * [MPV_REMOTE_FLOOR_BYTES]. With buffer tuning OFF, the plain floor (matching the merged flag-off path).
     */
    fun mpvRemoteReadAheadBytes(context: Context): Long {
        if (!BufferTuningSetting.isEnabled(context)) return MPV_REMOTE_FLOOR_BYTES
        val plan = currentPlan(context)
        val ramScaled = (ramBudgetBytes(context) * plan.ramFraction).toLong()
        val freeClamp = DiskCacheSetting.freeDiskBytes(context)
            ?.let { (it * DiskCacheSetting.FREE_DISK_FRACTION).toLong() }
        val clamped = if (freeClamp != null) minOf(ramScaled, freeClamp) else ramScaled
        return maxOf(clamped, MPV_REMOTE_FLOOR_BYTES)
    }

    /**
     * ExoPlayer bandwidth-meter seed: the measured link speed (bits/s) when a fresh sweep exists, else the
     * conservative 50 Mbps default so the first chunk of a fast stream is not throttled by a cold estimate.
     */
    fun initialBitrateEstimate(context: Context): Long {
        val measuredBps = freshestLinkBps()
        return if (measuredBps != null) (measuredBps * 8).coerceAtLeast(DEFAULT_INITIAL_BITRATE_BPS) else DEFAULT_INITIAL_BITRATE_BPS
    }

    /**
     * Record the just-loaded stream, and (opted in, unmetered, stale, buffer-tuning on) kick a background
     * link sweep against it so the NEXT play is measured. No-op for a non-HTTP / local / loopback URL, and
     * whenever a sweep is already in flight. Never throws and never touches the caller's thread beyond the
     * cheap guards.
     */
    fun noteStream(context: Context, url: String?, headers: Map<String, String>) {
        val target = url?.takeIf { it.startsWith("http://", true) || it.startsWith("https://", true) } ?: return
        val host = LinkSpeedProbe.hostOf(target)
        if (host.isBlank() || isLoopbackHost(host)) return
        lastStreamHost = host

        if (!AdaptiveProbeSetting.isEnabled(context) || !BufferTuningSetting.isEnabled(context)) return
        if (isFresh(host)) return // a fresh measurement already exists -> nothing to re-measure
        if (isMetered(context)) return
        if (!probing.compareAndSet(false, true)) return

        val appContext = context.applicationContext
        scope.launch {
            try {
                val result = LinkSpeedProbe.probe(target, headers)
                if (result != null) {
                    probeByHost[host] = Cached(result, System.currentTimeMillis())
                    Log.i(
                        TAG,
                        "link sweep for $host: ${result.sustainedBps * 8 / 1_000_000} Mbps " +
                            "(stable=${result.stable}, samples=${result.sampleCount})",
                    )
                }
            } catch (_: Throwable) {
                // Fail-soft: a failed sweep just leaves the planner on the RAM-tier ladder.
            } finally {
                probing.set(false)
                // Touch appContext so the captured reference is meaningful to a future extension (e.g.
                // persistence); keeps the gate self-contained without leaking an Activity context.
                appContext.hashCode()
            }
        }
    }

    // ---- internals ----

    private fun ramBudgetBytes(context: Context): Long =
        DeviceMemoryTier.safeBufferMb(context).toLong() * BYTES_PER_MB

    /** Freshest non-stale measurement (bytes/s), preferring the last-played host, else any host. */
    private fun freshestLinkBps(): Long? {
        val now = System.currentTimeMillis()
        probeByHost[lastStreamHost]?.takeIf { now - it.atMs <= PROBE_STALE_MS }?.let { return it.result.sustainedBps }
        return probeByHost.values
            .filter { now - it.atMs <= PROBE_STALE_MS }
            .maxByOrNull { it.atMs }
            ?.result
            ?.sustainedBps
    }

    private fun isFresh(host: String): Boolean {
        val cached = probeByHost[host] ?: return false
        return System.currentTimeMillis() - cached.atMs <= PROBE_STALE_MS
    }

    private fun isLoopbackHost(host: String): Boolean =
        host == "127.0.0.1" || host.equals("localhost", true) || host == "::1"

    /** True when the active network is metered (mobile data / metered hotspot). Fail-safe: metered on error. */
    private fun isMetered(context: Context): Boolean = runCatching {
        val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return true
        cm.isActiveNetworkMetered
    }.getOrDefault(true)

    private const val DEFAULT_INITIAL_BITRATE_BPS = 50_000_000L
}

/**
 * Opt-in kill switch for the background link-speed SWEEP. The RAM-tier + intent adaptive tuning is always
 * active (it costs nothing); this flag gates only the network measurement, which downloads a bounded
 * sample (~72 MiB) and so ships OFF by default and only ever runs on an UNMETERED connection. Stored in
 * the shared `vortx_settings` file, flippable like the other player kill switches.
 */
object AdaptiveProbeSetting {
    const val KEY = "vortx.player.adaptiveProbe"
    const val DEFAULT = false

    private const val SETTINGS_FILE = "vortx_settings"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

    fun isEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY, DEFAULT)

    fun setEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY, enabled).apply()
    }
}
