package com.vortx.android.player

import com.vortx.android.engine.DeadlinePublicDns
import com.vortx.android.engine.PublicAddressPolicy
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.ConnectionPool
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Proxy
import java.net.URI
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.resume
import java.util.concurrent.atomic.AtomicBoolean

/** Bounded index GETs: private DNS is admitted only for the originally installed add-on origin. */
internal object AddonSubtitleIndexTransport {
    internal data class Result(val status: Int, val finalIndexUri: String, val body: ByteArray?)
    internal data class FileResult(
        val status: Int,
        val finalFileUri: String,
        val contentType: String?,
        val contentDisposition: String?,
        val body: ByteArray?,
    )

    fun deadlineAfterTimeout(): Long = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS.toLong())

    suspend fun get(endpoint: String, originalInstalledBase: String, deadline: Long): Result? {
        val originalText = originalInstalledBase.trim()
        if (originalText.toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
        val original = originalText.toHttpUrlOrNull()?.newBuilder()?.fragment(null)?.build() ?: return null
        if (!isAllowed(original, original) || !sameRawLiteral(originalText, original)) return null
        val initialText = endpoint.trim()
        if (initialText.toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
        var current = initialText.toHttpUrlOrNull()?.newBuilder()?.fragment(null)?.build() ?: return null
        if (!sameRawLiteral(initialText, current) || !isAllowed(current, original)) return null

        for (hop in 0..MAX_REDIRECTS) {
            val remainingNanos = deadline - System.nanoTime()
            if (remainingNanos <= 0L) return null
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
            val response = execute(current, original, remainingMs) ?: return null
            if (System.nanoTime() >= deadline) return null
            if (response.status in REDIRECTS) {
                if (hop == MAX_REDIRECTS) return null
                val location = response.location?.takeIf {
                    it.isNotBlank() && it.none(::isControl) && it.toByteArray(Charsets.UTF_8).size <= MAX_RESOURCE_URL_BYTES
                } ?: return null
                val next = current.resolve(location) ?: return null
                if (!sameRawLiteral(location, next) || !isAllowed(next, original) ||
                    next.toString().toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
                current = next
                continue
            }
            val finalUri = current.newBuilder().fragment(null).build().toString()
            if (finalUri.toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
            return Result(response.status, finalUri, response.body)
        }
        return null
    }

    /** Fetch one subtitle file under the installed manifest origin's private-address authority. */
    suspend fun getFile(
        endpoint: String,
        originalInstalledBase: String,
        deadline: Long,
        permitsUse: () -> Boolean,
        isCancelled: () -> Boolean,
    ): FileResult? {
        fun live() = runCatching { permitsUse() && !isCancelled() }.getOrDefault(false)
        if (!live()) return null
        val originalText = originalInstalledBase.trim()
        if (originalText.toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
        val original = originalText.toHttpUrlOrNull()?.newBuilder()?.fragment(null)?.build() ?: return null
        if (!isAllowed(original, original) || !sameRawLiteral(originalText, original)) return null
        val initialText = endpoint.trim()
        if (initialText.toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
        var current = initialText.toHttpUrlOrNull()?.newBuilder()?.fragment(null)?.build() ?: return null
        if (!sameRawLiteral(initialText, current) || !isAllowed(current, original)) return null
        for (hop in 0..MAX_REDIRECTS) {
            if (!live()) return null
            val remainingNanos = deadline - System.nanoTime()
            if (remainingNanos <= 0L) return null
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
            val response = execute(current, original, remainingMs, MAX_FILE_BYTES, ::live) ?: return null
            if (!live() || System.nanoTime() >= deadline) return null
            if (response.status in REDIRECTS) {
                if (hop == MAX_REDIRECTS) return null
                val location = response.location?.takeIf {
                    it.isNotBlank() && it.none(::isControl) && it.toByteArray(Charsets.UTF_8).size <= MAX_RESOURCE_URL_BYTES
                } ?: return null
                val next = current.resolve(location) ?: return null
                if (!sameRawLiteral(location, next) || !isAllowed(next, original) ||
                    next.toString().toByteArray(Charsets.UTF_8).size > MAX_RESOURCE_URL_BYTES) return null
                current = next
                continue
            }
            return FileResult(response.status, current.toString(), response.contentType,
                response.contentDisposition, response.body)
        }
        return null
    }

    private data class Hop(
        val status: Int, val location: String?, val body: ByteArray?,
        val contentType: String? = null, val contentDisposition: String? = null,
    )

    private suspend fun execute(
        url: HttpUrl, original: HttpUrl, timeoutMs: Long,
        maxBytes: Int = MAX_RESPONSE_BYTES, live: () -> Boolean = { true },
    ): Hop? =
        withTimeoutOrNull(timeoutMs.coerceAtLeast(1L)) {
            CALL_ADMISSION.acquire()
            var leaseTransferredToCall = false
            try {
                suspendCancellableCoroutine<Hop?> { continuation ->
                    if (!continuation.isActive) return@suspendCancellableCoroutine
                    if (!live()) {
                        continuation.resume(null)
                        return@suspendCancellableCoroutine
                    }
                    val released = AtomicBoolean(false)
                    fun releaseLease() {
                        if (released.compareAndSet(false, true)) CALL_ADMISSION.release()
                    }
                    val timeout = timeoutMs.coerceAtLeast(1L)
                    val client = OkHttpClient.Builder()
                        .dispatcher(DISPATCHER)
                        // Keep connection pools private to this origin-scoped client/request.
                        .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
                        .proxy(Proxy.NO_PROXY)
                        .dns(DeadlinePublicDns(timeout) { host ->
                            if (sameOrigin(url, original) && host == original.host) PublicAddressPolicy.requireAddon(host)
                            else PublicAddressPolicy.requirePublic(host)
                        })
                        .followRedirects(false)
                        .followSslRedirects(false)
                        .connectTimeout(timeout, TimeUnit.MILLISECONDS)
                        .readTimeout(timeout, TimeUnit.MILLISECONDS)
                        .callTimeout(timeout, TimeUnit.MILLISECONDS)
                        .build()
                    val call = client.newCall(Request.Builder().url(url).get().build())
                    // Index callers keep their original behavior. Only selected file preparation has
                    // an external owner witness to monitor while headers/body are blocked.
                    val livenessWatcher = if (maxBytes == MAX_FILE_BYTES) CoroutineScope(continuation.context).launch(Dispatchers.Default) {
                        while (isActive) {
                            if (!live()) { call.cancel(); break }
                            delay(LIVENESS_POLL_MS)
                        }
                    } else null
                    continuation.invokeOnCancellation { livenessWatcher?.cancel(); call.cancel() }
                    // From here, the callback owns this permit until response-close/onFailure.
                    leaseTransferredToCall = true
                    try {
                        call.enqueue(object : Callback {
                            override fun onFailure(call: Call, error: IOException) {
                                try {
                                    if (continuation.isActive) runCatching { continuation.resume(null) }
                                } finally {
                                    livenessWatcher?.cancel()
                                    releaseLease()
                                }
                            }

                            override fun onResponse(call: Call, response: Response) {
                                val result = try {
                                    response.use { reply ->
                                        val location = reply.header("Location")
                                        if (reply.code in REDIRECTS) Hop(reply.code, location, null)
                                        else if (reply.code !in 200..299) Hop(reply.code, null, null)
                                        else if (!live()) null else Hop(reply.code, null,
                                            readBounded(reply, maxBytes, live),
                                            reply.header("Content-Type"), reply.header("Content-Disposition"))
                                    }
                                } catch (_: Exception) {
                                    null
                                } finally {
                                    // Structured watcher children must settle on success as well as
                                    // failure, or withTimeout waits for them until its deadline.
                                    livenessWatcher?.cancel()
                                    releaseLease()
                                }
                                if (continuation.isActive) runCatching { continuation.resume(result) }
                            }
                        })
                    } catch (_: Exception) {
                        livenessWatcher?.cancel()
                        releaseLease()
                        if (continuation.isActive) runCatching { continuation.resume(null) }
                    }
                }
            } finally {
                // Construction failure or cancellation before enqueue keeps ownership in this coroutine.
                if (!leaseTransferredToCall) CALL_ADMISSION.release()
            }
        }

    private fun readBounded(response: Response, maxBytes: Int, live: () -> Boolean): ByteArray? {
        val body = response.body ?: return null
        if (body.contentLength() > maxBytes) return null
        return try {
            body.byteStream().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                var total = 0
                while (true) {
                    if (!live()) return null
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) return null
                    total += count
                    if (total > maxBytes) return null
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } catch (_: IOException) {
            null
        }
    }

    private fun isAllowed(url: HttpUrl, original: HttpUrl): Boolean {
        if (url.scheme != "http" && url.scheme != "https") return false
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) return false
        return runCatching {
            if (sameOrigin(url, original)) PublicAddressPolicy.requireAddonLiteralOrHostname(url.host)
            else PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
        }.isSuccess
    }

    internal fun sameRawLiteral(raw: String, canonical: HttpUrl): Boolean {
        val canonicalHost = canonical.host
        val canonicalIpv4 = canonicalHost.isNotEmpty() && canonicalHost.all { it.isDigit() || it == '.' }
        val canonicalIpv6 = canonicalHost.contains(':')
        if (!canonicalIpv4 && !canonicalIpv6) return true

        val reference = runCatching { URI(raw) }.getOrNull()
        if (reference == null) {
            val absoluteOrAuthority = raw.startsWith("//") || raw.substringBefore('/').substringBefore('?').contains(':')
            return !absoluteOrAuthority
        }
        val rawAuthority = reference.rawAuthority
        if (reference.isAbsolute && rawAuthority == null) return false
        if (rawAuthority == null) return true // A relative path inherits the already-validated base host.
        val rawHost = reference.host?.removeSurrounding("[", "]") ?: return false
        return if (canonicalIpv4) {
            rawHost == canonicalHost
        } else {
            rawHost.contains(':') && runCatching { PublicAddressPolicy.requireAddonLiteralOrHostname(rawHost) }.isSuccess
        }
    }

    private fun sameOrigin(first: HttpUrl, second: HttpUrl): Boolean =
        first.scheme == second.scheme && first.host == second.host && first.port == second.port

    private fun isControl(char: Char): Boolean = char.code < 0x20 || char.code == 0x7f

    private val DISPATCHER = Dispatcher(
        ThreadPoolExecutor(4, 4, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(4), ThreadFactory { task ->
            Thread(task, "vortx-addon-subtitle-index").apply { isDaemon = true }
        }),
    ).apply {
        maxRequests = 4
        maxRequestsPerHost = 2
    }
    private val CALL_ADMISSION = Semaphore(16)

    private const val TIMEOUT_MS = 15_000
    private const val MAX_RESPONSE_BYTES = 1024 * 1024
    private const val MAX_FILE_BYTES = 8 * 1024 * 1024
    private const val MAX_RESOURCE_URL_BYTES = 128 * 1024
    private const val MAX_REDIRECTS = 5
    private const val LIVENESS_POLL_MS = 100L
    private val REDIRECTS = setOf(301, 302, 303, 307, 308)
}
