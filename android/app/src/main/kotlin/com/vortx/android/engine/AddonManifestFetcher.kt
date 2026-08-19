package com.vortx.android.engine

import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.Callable
import java.util.concurrent.CancellationException
import java.util.concurrent.Future
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.locks.LockSupport

internal class AddonManifestFetcher(
    private val timeoutMs: Int,
    private val hostValidator: (String) -> Unit = { PublicAddressPolicy.requireLiteralPublicOrHostname(it) },
    private val transport: ManifestTransport = OkHttpManifestTransport(timeoutMs),
    private val nanoTime: () -> Long = System::nanoTime,
) {
    fun fetch(url: String): JSONObject? {
        val startedAt = nanoTime()
        var current = url.toHttpUrlOrNull()?.takeIf(::isAllowedUrl) ?: return null
        var redirects = 0
        val timeoutNanos = TimeUnit.MILLISECONDS.toNanos(timeoutMs.toLong())

        while (true) {
            val remainingNanos = timeoutNanos - (nanoTime() - startedAt)
            if (remainingNanos <= 0) return null
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1)
            val response = runCatching { transport.execute(current, remainingMs) }.getOrNull() ?: return null
            if (response.statusCode in REDIRECT_STATUS_CODES) {
                if (redirects >= MAX_REDIRECTS) return null
                val location = response.location ?: return null
                current = current.resolve(location)?.takeIf(::isAllowedUrl) ?: return null
                redirects += 1
                continue
            }
            if (response.statusCode !in 200..299) return null
            val body = response.body ?: return null
            val manifest = runCatching { JSONObject(body) }.getOrNull() ?: return null
            return manifest.takeIf {
                it.optString("id").isNotBlank() && it.optString("name").isNotBlank()
            }
        }
    }

    private fun isAllowedUrl(url: HttpUrl): Boolean {
        if (url.scheme != "http" && url.scheme != "https") return false
        if (url.username.isNotEmpty() || url.password.isNotEmpty()) return false
        return runCatching { hostValidator(url.host) }.isSuccess
    }

    private companion object {
        const val MAX_REDIRECTS = 5
        val REDIRECT_STATUS_CODES = setOf(301, 302, 303, 307, 308)
    }
}

internal fun interface ManifestTransport {
    fun execute(url: HttpUrl, timeoutMs: Long): ManifestTransportResponse
}

internal data class ManifestTransportResponse(
    val statusCode: Int,
    val location: String? = null,
    val body: String? = null,
)

private class OkHttpManifestTransport(timeoutMs: Int) : ManifestTransport {
    private val client = buildAddonManifestClient(timeoutMs)

    override fun execute(url: HttpUrl, timeoutMs: Long): ManifestTransportResponse {
        val requestClient = client.newBuilder()
            .dns(DeadlinePublicDns(timeoutMs))
            .build()
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "VortX-Android/1.0")
            .get()
            .build()
        val call = requestClient.newCall(request)
        call.timeout().timeout(timeoutMs, TimeUnit.MILLISECONDS)
        return call.execute().use { response ->
            ManifestTransportResponse(
                statusCode = response.code,
                location = response.header("Location"),
                body = if (response.isSuccessful) response.readLimitedBody() else null,
            )
        }
    }

    private fun Response.readLimitedBody(): String? {
        val responseBody = body ?: return null
        val declaredLength = responseBody.contentLength()
        if (declaredLength > MAX_MANIFEST_BYTES) return null

        return responseBody.byteStream().use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                total += count
                if (total > MAX_MANIFEST_BYTES) return null
                output.write(buffer, 0, count)
            }
            output.toString(Charsets.UTF_8.name())
        }
    }

    private companion object {
        const val MAX_MANIFEST_BYTES = 1024 * 1024
    }
}

internal fun buildAddonManifestClient(timeoutMs: Int): OkHttpClient = OkHttpClient.Builder()
    .proxy(Proxy.NO_PROXY)
    .dns(DeadlinePublicDns(timeoutMs.toLong()))
    .followRedirects(false)
    .followSslRedirects(false)
    .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .callTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .build()

internal class DeadlinePublicDns(
    private val timeoutMs: Long,
    private val resolver: (String) -> List<InetAddress> = PublicAddressPolicy::requirePublic,
) : Dns {
    override fun lookup(hostname: String): List<InetAddress> {
        val timeoutNanos = TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(1))
        val deadline = System.nanoTime() + timeoutNanos
        val admitted = try {
            DNS_ADMISSION.tryAcquire(timeoutNanos, TimeUnit.NANOSECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw UnknownHostException("Interrupted while waiting for add-on DNS capacity").apply {
                initCause(error)
            }
        }
        if (!admitted) throw UnknownHostException("Add-on DNS capacity wait exceeded its deadline")

        val lease = DnsAdmissionLease(DNS_ADMISSION::release)
        val future = try {
            var scheduled: Future<List<InetAddress>>? = null
            while (scheduled == null) {
                try {
                    scheduled = DNS_EXECUTOR.submit(
                        Callable {
                            if (!lease.tryStart()) {
                                throw CancellationException("Add-on DNS lookup cancelled before resolver start")
                            }
                            try {
                                resolver(hostname)
                            } finally {
                                // A resolver may ignore interruption. Keep its shared capacity claimed until
                                // the worker really exits rather than creating a slot that does not exist.
                                lease.releaseRunning()
                            }
                        },
                    )
                } catch (rejected: RejectedExecutionException) {
                    val remaining = deadline - System.nanoTime()
                    if (remaining <= 0) throw rejected
                    // A completing worker releases admission immediately before it returns to the
                    // SynchronousQueue. Retry that tiny hand-off race within the original DNS deadline.
                    LockSupport.parkNanos(minOf(remaining, TimeUnit.MILLISECONDS.toNanos(1)))
                    if (Thread.interrupted()) throw InterruptedException("DNS scheduling interrupted")
                }
            }
            requireNotNull(scheduled)
        } catch (error: Exception) {
            lease.releasePending()
            if (error is InterruptedException) Thread.currentThread().interrupt()
            throw UnknownHostException("Unable to schedule add-on DNS lookup").apply { initCause(error) }
        }
        return try {
            val remaining = (deadline - System.nanoTime()).coerceAtLeast(1)
            future.get(remaining, TimeUnit.NANOSECONDS)
        } catch (error: TimeoutException) {
            future.cancel(true)
            lease.releasePending()
            throw UnknownHostException("Add-on DNS lookup exceeded its deadline").apply {
                initCause(error)
            }
        } catch (error: Exception) {
            future.cancel(true)
            lease.releasePending()
            val cause = error.cause ?: error
            if (cause is UnknownHostException) throw cause
            throw UnknownHostException("Unable to resolve add-on host").apply {
                initCause(cause)
            }
        }
    }

    private companion object {
        val threadIds = AtomicInteger()
        val DNS_ADMISSION = Semaphore(2, true)
        val DNS_EXECUTOR = ThreadPoolExecutor(
            0,
            2,
            30,
            TimeUnit.SECONDS,
            SynchronousQueue(),
        ) { task ->
            Thread(task, "vortx-addon-dns-${threadIds.incrementAndGet()}").apply {
                isDaemon = true
            }
        }
    }
}

/** Exactly-once ownership for one permit between lookup cancellation and its DNS worker. */
internal class DnsAdmissionLease(private val releasePermit: () -> Unit) {
    private val state = AtomicReference(State.PENDING)

    fun tryStart(): Boolean = state.compareAndSet(State.PENDING, State.RUNNING)

    fun releasePending(): Boolean = state.compareAndSet(State.PENDING, State.RELEASED).also { released ->
        if (released) releasePermit()
    }

    fun releaseRunning(): Boolean = state.compareAndSet(State.RUNNING, State.RELEASED).also { released ->
        if (released) releasePermit()
    }

    private enum class State {
        PENDING,
        RUNNING,
        RELEASED,
    }
}

internal object PublicAddressPolicy {
    fun requireLiteralPublicOrHostname(hostname: String) {
        val address = when {
            hostname.contains(':') -> parseIpv6Literal(hostname)
            hostname.isNotEmpty() && hostname.all { it.isDigit() || it == '.' } ->
                parseIpv4Literal(hostname)
            else -> return
        } ?: throw UnknownHostException("Invalid add-on address")
        if (isBlocked(address)) {
            throw UnknownHostException("Add-on URL contains a non-public address")
        }
    }

    fun requirePublic(hostname: String): List<InetAddress> {
        val addresses = try {
            InetAddress.getAllByName(hostname).toList()
        } catch (error: Exception) {
            throw UnknownHostException("Unable to resolve add-on host").apply { initCause(error) }
        }
        if (addresses.isEmpty() || addresses.any(::isBlocked)) {
            throw UnknownHostException("Add-on host resolved to a non-public address")
        }
        return addresses
    }

    internal fun isBlocked(address: InetAddress): Boolean {
        if (
            address.isAnyLocalAddress ||
            address.isLoopbackAddress ||
            address.isLinkLocalAddress ||
            address.isSiteLocalAddress ||
            address.isMulticastAddress
        ) {
            return true
        }

        val bytes = address.address
        return when (bytes.size) {
            4 -> isBlockedIpv4(bytes)
            16 -> isBlockedIpv6(bytes)
            else -> true
        }
    }

    private fun parseIpv4Literal(hostname: String): InetAddress? {
        val parts = hostname.split('.')
        if (parts.size != 4) return null

        val bytes = ByteArray(4)
        for ((index, part) in parts.withIndex()) {
            if (
                part.isEmpty() ||
                part.length > 3 ||
                (part.length > 1 && part.startsWith('0')) ||
                part.any { !it.isDigit() }
            ) {
                return null
            }
            val value = part.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
            bytes[index] = value.toByte()
        }
        return InetAddress.getByAddress(bytes)
    }

    private fun parseIpv6Literal(hostname: String): InetAddress? {
        if (hostname.isEmpty() || hostname.contains('%')) return null

        val compression = hostname.indexOf("::")
        if (compression >= 0 && hostname.indexOf("::", compression + 2) >= 0) return null

        val leftText: String
        val rightText: String
        if (compression >= 0) {
            leftText = hostname.substring(0, compression)
            rightText = hostname.substring(compression + 2)
        } else {
            if (hostname.startsWith(':') || hostname.endsWith(':')) return null
            leftText = hostname
            rightText = ""
        }

        val left = parseIpv6Section(
            leftText,
            allowIpv4Tail = compression < 0,
        ) ?: return null
        val right = if (compression >= 0) {
            parseIpv6Section(rightText, allowIpv4Tail = true) ?: return null
        } else {
            emptyList()
        }

        val explicitGroups = left.size + right.size
        val zeroGroups = if (compression >= 0) {
            if (explicitGroups >= 8) return null
            8 - explicitGroups
        } else {
            if (explicitGroups != 8) return null
            0
        }

        val groups = left + List(zeroGroups) { 0 } + right
        val bytes = ByteArray(16)
        groups.forEachIndexed { index, value ->
            bytes[index * 2] = (value ushr 8).toByte()
            bytes[index * 2 + 1] = value.toByte()
        }
        return InetAddress.getByAddress(bytes)
    }

    private fun parseIpv6Section(
        section: String,
        allowIpv4Tail: Boolean,
    ): List<Int>? {
        if (section.isEmpty()) return emptyList()
        if (section.startsWith(':') || section.endsWith(':')) return null

        val parts = section.split(':')
        val groups = mutableListOf<Int>()
        for ((index, part) in parts.withIndex()) {
            if (part.contains('.')) {
                if (!allowIpv4Tail || index != parts.lastIndex) return null
                val ipv4 = parseIpv4Literal(part)?.address ?: return null
                groups += ((ipv4[0].toInt() and 0xff) shl 8) or
                    (ipv4[1].toInt() and 0xff)
                groups += ((ipv4[2].toInt() and 0xff) shl 8) or
                    (ipv4[3].toInt() and 0xff)
                continue
            }
            if (
                part.isEmpty() ||
                part.length > 4 ||
                part.any { !it.isDigit() && it.lowercaseChar() !in 'a'..'f' }
            ) {
                return null
            }
            groups += part.toInt(16)
        }
        return groups
    }

    private fun isBlockedIpv4(bytes: ByteArray): Boolean {
        val first = bytes[0].toInt() and 0xff
        val second = bytes[1].toInt() and 0xff
        val third = bytes[2].toInt() and 0xff

        return when {
            first == 0 -> true
            first == 10 -> true
            first == 100 && second in 64..127 -> true
            first == 127 -> true
            first == 169 && second == 254 -> true
            first == 172 && second in 16..31 -> true
            first == 192 && second == 0 && third == 0 -> true
            first == 192 && second == 0 && third == 2 -> true
            first == 192 && second == 88 && third == 99 -> true
            first == 192 && second == 168 -> true
            first == 198 && second in 18..19 -> true
            first == 198 && second == 51 && third == 100 -> true
            first == 203 && second == 0 && third == 113 -> true
            first >= 224 -> true
            else -> false
        }
    }

    private fun isBlockedIpv6(bytes: ByteArray): Boolean {
        val first = bytes[0].toInt() and 0xff
        val second = bytes[1].toInt() and 0xff

        if (bytes.copyOfRange(0, 10).all { it == 0.toByte() } &&
            bytes[10] == 0xff.toByte() &&
            bytes[11] == 0xff.toByte()
        ) {
            return isBlockedIpv4(bytes.copyOfRange(12, 16))
        }

        if (bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x00, 0x64, 0xff.toByte(), 0x9b.toByte())) &&
            bytes.copyOfRange(4, 12).all { it == 0.toByte() }
        ) {
            return isBlockedIpv4(bytes.copyOfRange(12, 16))
        }

        val isIsatap = (
            (bytes[8] == 0.toByte() && bytes[9] == 0.toByte()) ||
                (bytes[8] == 0x02.toByte() && bytes[9] == 0.toByte())
            ) &&
            bytes[10] == 0x5e.toByte() &&
            bytes[11] == 0xfe.toByte()
        if (isIsatap) {
            return isBlockedIpv4(bytes.copyOfRange(12, 16))
        }

        if (first !in 0x20..0x3f) return true

        if (first == 0x20 && second == 0x02) {
            return isBlockedIpv4(bytes.copyOfRange(2, 6))
        }

        if (first == 0x20 && second == 0x01 && bytes[2].toInt() and 0xfe == 0) {
            return true
        }
        if (bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x20, 0x01, 0x0d, 0xb8.toByte()))) {
            return true
        }
        if (first == 0x3f && bytes[1] == 0xff.toByte() && bytes[2].toInt() and 0xf0 == 0) {
            return true
        }

        return false
    }
}
