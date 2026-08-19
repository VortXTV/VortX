package com.vortx.android.engine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** Live reachability of one installed add-on's manifest endpoint. */
sealed interface AddonHealth {
    data object Unknown : AddonHealth
    data object Checking : AddonHealth
    data class Online(val latencyMillis: Long) : AddonHealth
    data class Slow(val latencyMillis: Long) : AddonHealth
    data object Unreachable : AddonHealth
}

internal fun interface AddonHealthProbe {
    suspend fun probe(url: HttpUrl): AddonProbeResult
}

internal data class AddonProbeResult(
    val statusCode: Int,
    val latencyMillis: Long,
)

/**
 * Concurrent, bounded manifest health checks for the installed add-on list. Results are keyed by a
 * canonical transport URL so equivalent URL spellings share one status. The caller owns the
 * coroutine lifetime; cancelling that caller cancels every child probe.
 */
class AddonHealthStore internal constructor(
    private val probe: AddonHealthProbe = OkHttpAddonHealthProbe(PROBE_TIMEOUT_MILLIS),
    private val nowMillis: () -> Long = ::monotonicMillis,
    private val timeoutMillis: Long = PROBE_TIMEOUT_MILLIS,
    private val slowThresholdMillis: Long = SLOW_THRESHOLD_MILLIS,
    private val rateLimitMillis: Long = BULK_RATE_LIMIT_MILLIS,
) {
    private val _status = MutableStateFlow<Map<String, AddonHealth>>(emptyMap())
    val status: StateFlow<Map<String, AddonHealth>> = _status.asStateFlow()

    private val rateLimitLock = Mutex()
    private val probePermits = Semaphore(MAX_CONCURRENT_STORE_PROBES)
    private var lastBulkProbeAtMillis: Long? = null
    private val generation = AtomicLong(0)

    /**
     * Probes every distinct URL concurrently. Returns false when a non-forced bulk request was
     * rate-limited or there was no valid URL to probe. A forced refresh always bypasses the bulk
     * rate limit. A newer accepted refresh owns publication, so late results cannot overwrite it.
     */
    suspend fun refresh(transportUrls: List<String>, force: Boolean = false): Boolean {
        val urls = transportUrls.mapNotNull(::normalizeUrl).distinct()
        if (urls.isEmpty()) {
            rateLimitLock.withLock {
                generation.incrementAndGet()
                lastBulkProbeAtMillis = null
                _status.value = emptyMap()
            }
            return false
        }

        val keys = urls.toSet()
        val refreshGeneration = rateLimitLock.withLock {
            val now = nowMillis()
            val last = lastBulkProbeAtMillis
            if (!force && last != null && now - last < rateLimitMillis) {
                null
            } else {
                lastBulkProbeAtMillis = now
                generation.incrementAndGet().also {
                    _status.update { current ->
                        current.filterKeys { it in keys } + urls.associateWith { AddonHealth.Checking }
                    }
                }
            }
        } ?: return false

        coroutineScope {
            urls.map { url ->
                async {
                    val health = check(url)
                    rateLimitLock.withLock {
                        if (generation.get() == refreshGeneration) {
                            _status.update { it + (url to health) }
                        }
                    }
                }
            }.awaitAll()
        }
        return true
    }

    /** Remaining wait before a non-forced bulk refresh may start. */
    internal suspend fun bulkRetryDelayMillis(): Long = rateLimitLock.withLock {
        val last = lastBulkProbeAtMillis ?: return@withLock 0L
        (rateLimitMillis - (nowMillis() - last)).coerceAtLeast(0L)
    }

    private suspend fun check(transportUrl: String): AddonHealth {
        val url = transportUrl.toHttpUrlOrNull()?.takeIf(::isAllowedProbeUrl)
            ?: return AddonHealth.Unreachable
        // Queue outside the per-URL clock. Every admitted URL receives a complete bounded attempt;
        // a long installed list cannot turn later rows into failures merely for waiting its turn.
        val result = probePermits.withPermit {
            try {
                withTimeoutOrNull(timeoutMillis.coerceAtLeast(1)) { probe.probe(url) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                null
            }
        } ?: return AddonHealth.Unreachable

        if (result.statusCode !in 200..399) return AddonHealth.Unreachable
        val latency = result.latencyMillis.coerceAtLeast(0)
        return if (latency <= slowThresholdMillis) {
            AddonHealth.Online(latency)
        } else {
            AddonHealth.Slow(latency)
        }
    }

    companion object {
        /** Canonical URL used both by the status map and row lookups. */
        fun normalizeUrl(transportUrl: String): String? {
            val url = transportUrl.trim().toHttpUrlOrNull() ?: return null
            if (url.scheme != "http" && url.scheme != "https") return null
            return url.toString()
        }

        internal fun isAllowedProbeUrl(url: HttpUrl): Boolean {
            if (url.scheme != "http" && url.scheme != "https") return false
            if (url.username.isNotEmpty() || url.password.isNotEmpty()) return false
            if (isStrictLoopbackHost(url.host)) return true
            return runCatching { PublicAddressPolicy.requireLiteralPublicOrHostname(url.host) }.isSuccess
        }

        internal fun isStrictLoopbackHost(host: String): Boolean {
            val lower = host.lowercase()
            if (lower == "localhost" || lower == "::1") return true
            val parts = lower.split('.')
            if (parts.size != 4 || parts.first() != "127") return false
            return parts.all { part ->
                part.isNotEmpty() &&
                    part.length <= 3 &&
                    (part.length == 1 || !part.startsWith('0')) &&
                    part.all(Char::isDigit) &&
                    part.toIntOrNull() in 0..255
            }
        }
    }
}

/**
 * A discard-response GET using the existing add-on manifest client's no-proxy and guarded-DNS
 * policy. Redirects stay disabled: a 3xx is itself a live response and no second target is visited.
 * Only strict loopback hosts swap to system DNS, preserving the installed local add-on exception.
 */
internal class OkHttpAddonHealthProbe(
    timeoutMillis: Long,
    private val publicClient: OkHttpClient = buildAddonManifestClient(
        timeoutMillis.coerceIn(1, Int.MAX_VALUE.toLong()).toInt(),
    ),
    private val loopbackClient: OkHttpClient = publicClient.newBuilder().dns(Dns.SYSTEM).build(),
    maxConcurrentProbes: Int = MAX_CONCURRENT_PROBES,
) : AddonHealthProbe {
    private val permits = Semaphore(maxConcurrentProbes.coerceAtLeast(1))

    override suspend fun probe(url: HttpUrl): AddonProbeResult = permits.withPermit {
        val startedAt = System.nanoTime()
        val client = if (AddonHealthStore.isStrictLoopbackHost(url.host)) loopbackClient else publicClient
        val statusCode = client.executeStatus(
            Request.Builder()
                .url(url)
                .header("User-Agent", "VortX-Android/1.0")
                .get()
                .build(),
        )
        val latencyMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)
        AddonProbeResult(statusCode = statusCode, latencyMillis = latencyMillis)
    }

    private companion object {
        // DeadlinePublicDns has two workers and no submission queue. Keeping at most two production
        // probes inside the network lane prevents an ordinary third cold lookup from being rejected.
        const val MAX_CONCURRENT_PROBES = 2
    }
}

private suspend fun OkHttpClient.executeStatus(request: Request): Int = suspendCancellableCoroutine { continuation ->
    val call = newCall(request)
    val completed = AtomicBoolean(false)
    fun complete(result: Result<Int>) {
        if (completed.compareAndSet(false, true)) continuation.resumeWith(result)
    }
    continuation.invokeOnCancellation {
        completed.set(true)
        call.cancel()
    }
    call.enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                complete(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                complete(runCatching { response.use { it.statusAfterDiscardingBody() } })
            }
        },
    )
}

private fun Response.statusAfterDiscardingBody(): Int {
    if (code !in 200..399) return code
    val responseBody = body ?: return code
    val declaredLength = responseBody.contentLength()
    if (declaredLength > MAX_MANIFEST_BYTES) return 0

    responseBody.byteStream().use { input ->
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > MAX_MANIFEST_BYTES) return 0
        }
    }
    return code
}

private fun monotonicMillis(): Long = TimeUnit.NANOSECONDS.toMillis(System.nanoTime())

private const val PROBE_TIMEOUT_MILLIS = 6_000L
private const val SLOW_THRESHOLD_MILLIS = 1_500L
private const val BULK_RATE_LIMIT_MILLIS = 20_000L
private const val MAX_MANIFEST_BYTES = 1024 * 1024
private const val MAX_CONCURRENT_STORE_PROBES = 2
