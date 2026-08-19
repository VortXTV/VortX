package com.vortx.android.player.tuning

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL
import kotlin.coroutines.coroutineContext
import kotlin.math.sqrt

/**
 * Measures the SUSTAINED link throughput to a real stream host, so the adaptive tuner
 * ([AdaptiveBufferPlanner]) can size the buffer to the network the device is actually on rather than to
 * the RAM tier alone. The sweep runs against the LAST-PLAYED stream URL (its CDN / debrid host), so the
 * number reflects the path the next play will use, not a synthetic speed-test server.
 *
 * Two phases, both fail-soft:
 *   1. WARM-UP ([WARMUP_BYTES], 8 MiB): read and discard so TCP slow-start and TLS setup are paid BEFORE
 *      the measured window, and are not counted against throughput.
 *   2. MEASURE ([MEASURE_BYTES] over [MEASURE_WINDOW_MS], a 64 MiB / 8 s window): read as fast as the link
 *      allows, sampling the byte counter every [SAMPLE_INTERVAL_MS] (500 ms). The sustained rate is total
 *      bytes over elapsed time; STABILITY is the coefficient of variation (stddev / mean) of the per-500 ms
 *      samples, judged stable at or below [CV_STABLE_MAX] (a bursty link with a high CV is a weak buffer
 *      signal even at a high average).
 *
 * Range requests strip the warm-up bytes from the measured read when the server honors `Range`; a server
 * that ignores it just serves from the start, which only makes the measurement conservative (some
 * slow-start creeps back in), never wrong. Every failure path returns null, so a probe never blocks or
 * degrades playback: the planner simply falls back to the RAM-tier ladder with no link input.
 */
object LinkSpeedProbe {

    /** Sustained link speed in bytes/second, plus whether the samples were steady enough to trust. */
    data class Result(val sustainedBps: Long, val stable: Boolean, val sampleCount: Int)

    const val WARMUP_BYTES: Long = 8L * 1024 * 1024
    const val MEASURE_BYTES: Long = 64L * 1024 * 1024
    const val MEASURE_WINDOW_MS: Long = 8_000
    const val SAMPLE_INTERVAL_MS: Long = 500
    const val CV_STABLE_MAX: Double = 0.35

    /** Below this many measured bytes (or fewer than two samples) the reading is discarded as noise. */
    private const val MIN_MEASURE_BYTES: Long = 4L * 1024 * 1024
    private const val MIN_SAMPLES = 2

    private const val CONNECT_TIMEOUT_MS = 10_000
    private const val READ_TIMEOUT_MS = 10_000
    private const val READ_CHUNK = 64 * 1024
    private const val TAG = "VortxLinkProbe"

    /**
     * Run the two-phase sweep against [url] with [headers] (the add-on's proxy headers / UA). Returns null
     * on any failure, an unusable host, or too little data to trust. Honors coroutine cancellation: a
     * superseded probe tears its socket down promptly.
     */
    suspend fun probe(url: String, headers: Map<String, String>): Result? = withContext(Dispatchers.IO) {
        runCatching {
            // Warm-up on its own connection: pays DNS + TLS + slow-start off the measured clock.
            if (!drain(url, headers, rangeStart = 0, rangeLen = WARMUP_BYTES, measure = false)) return@runCatching null
            coroutineContext.ensureActive()
            measure(url, headers)
        }.getOrElse {
            if (it is CancellationException) throw it
            Log.i(TAG, "link probe failed for host ${hostOf(url)}: ${it.message}")
            null
        }
    }

    /** Open a GET with a byte-range and finite timeouts. Reads honor cancellation via ensureActive(). */
    private fun open(url: String, headers: Map<String, String>, rangeStart: Long, rangeLen: Long): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            setRequestProperty("Range", "bytes=$rangeStart-${rangeStart + rangeLen - 1}")
            headers.forEach { (k, v) -> setRequestProperty(k, v) }
        }

    /** Read [rangeLen] bytes and discard them. When [measure] is false this is the warm-up (no timing). */
    private suspend fun drain(url: String, headers: Map<String, String>, rangeStart: Long, rangeLen: Long, measure: Boolean): Boolean {
        val conn = open(url, headers, rangeStart, rangeLen)
        return try {
            val code = conn.responseCode
            if (code !in 200..299) return false
            val buf = ByteArray(READ_CHUNK)
            conn.inputStream.use { input ->
                var total = 0L
                while (total < rangeLen) {
                    coroutineContext.ensureActive()
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                }
                total > 0L || !measure
            }
        } catch (e: CancellationException) {
            runCatching { conn.disconnect() }
            throw e
        } catch (_: Throwable) {
            false
        } finally {
            runCatching { conn.disconnect() }
        }
    }

    /** The measured window: read up to [MEASURE_BYTES] for up to [MEASURE_WINDOW_MS], sampling every 500 ms. */
    private suspend fun measure(url: String, headers: Map<String, String>): Result? {
        val conn = open(url, headers, rangeStart = WARMUP_BYTES, rangeLen = MEASURE_BYTES)
        return try {
            val code = conn.responseCode
            if (code !in 200..299) return null
            val buf = ByteArray(READ_CHUNK)
            val samples = mutableListOf<Long>()
            var total = 0L
            var sampleBytes = 0L
            val start = System.nanoTime()
            var nextSampleAt = start + SAMPLE_INTERVAL_MS * 1_000_000
            val deadline = start + MEASURE_WINDOW_MS * 1_000_000
            conn.inputStream.use { input ->
                while (total < MEASURE_BYTES) {
                    coroutineContext.ensureActive()
                    val n = input.read(buf)
                    if (n < 0) break
                    total += n
                    sampleBytes += n
                    val now = System.nanoTime()
                    if (now >= nextSampleAt) {
                        samples += sampleBytes
                        sampleBytes = 0L
                        nextSampleAt += SAMPLE_INTERVAL_MS * 1_000_000
                    }
                    if (now >= deadline) break
                }
            }
            val elapsedNs = (System.nanoTime() - start).coerceAtLeast(1)
            if (total < MIN_MEASURE_BYTES || samples.size < MIN_SAMPLES) return null
            val sustainedBps = total * 1_000_000_000L / elapsedNs
            Result(sustainedBps = sustainedBps, stable = isStable(samples), sampleCount = samples.size)
        } catch (e: CancellationException) {
            runCatching { conn.disconnect() }
            throw e
        } catch (_: Throwable) {
            null
        } finally {
            runCatching { conn.disconnect() }
        }
    }

    /** Coefficient of variation of the per-window samples <= [CV_STABLE_MAX]. Pure, so it is testable. */
    internal fun isStable(samples: List<Long>): Boolean {
        if (samples.size < MIN_SAMPLES) return false
        val mean = samples.sumOf { it.toDouble() } / samples.size
        if (mean <= 0.0) return false
        val variance = samples.sumOf { val d = it - mean; d * d } / samples.size
        val cv = sqrt(variance) / mean
        return cv <= CV_STABLE_MAX
    }

    /** The host of [url], or a blank string when it cannot be parsed (used only for logging/keys). */
    fun hostOf(url: String): String = runCatching { URL(url).host ?: "" }.getOrDefault("")
}
