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
import java.util.concurrent.TimeUnit

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
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "VortX-Android/1.0")
            .get()
            .build()
        val call = client.newCall(request)
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
    .dns(PublicOnlyDns)
    .followRedirects(false)
    .followSslRedirects(false)
    .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .callTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
    .build()

private object PublicOnlyDns : Dns {
    override fun lookup(hostname: String): List<InetAddress> = PublicAddressPolicy.requirePublic(hostname)
}

internal object PublicAddressPolicy {
    fun requireLiteralPublicOrHostname(hostname: String) {
        val isLiteral = hostname.contains(':') ||
            hostname.split('.').let { parts ->
                parts.size == 4 && parts.all { part -> part.toIntOrNull() in 0..255 }
            }
        if (!isLiteral) return
        val address = runCatching { InetAddress.getByName(hostname) }.getOrNull()
            ?: throw UnknownHostException("Invalid add-on address")
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
