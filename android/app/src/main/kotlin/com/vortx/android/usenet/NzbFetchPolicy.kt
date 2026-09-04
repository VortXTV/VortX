package com.vortx.android.usenet

import com.vortx.android.engine.PublicAddressPolicy
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.IOException
import java.net.InetAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

/** Testable SSRF and size boundary used for every initial NZB URL and redirect hop. */
internal object NzbFetchPolicy {
    const val MAX_BYTES = 4 * 1024 * 1024

    /** A host URL paired with the exact public DNS answers admitted for this request hop. */
    data class CheckedRequest(val url: HttpUrl, val addresses: List<InetAddress>)

    fun checkedRequest(
        raw: String,
        resolve: (String) -> List<InetAddress> = PublicAddressPolicy::requirePublic,
    ): CheckedRequest {
        val url = raw.toHttpUrlOrNull()
            ?: throw UsenetLocalResolver.ResolveException("invalid NZB URL")
        if (url.scheme != "https" || url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw UsenetLocalResolver.ResolveException("NZB URL must be HTTPS without user info")
        }
        return try {
            // Reject obfuscated/literal non-global addresses before resolution, then demand every DNS answer
            // be global-unicast. Keeping the original hostname preserves TLS SNI and HTTP Host.
            PublicAddressPolicy.requireLiteralPublicOrHostname(url.host)
            val addresses = resolve(url.host)
            if (addresses.isEmpty() || addresses.any(PublicAddressPolicy::isBlocked)) {
                throw UnknownHostException("NZB host resolved to a non-public address")
            }
            CheckedRequest(url, addresses)
        } catch (_: Exception) {
            throw UsenetLocalResolver.ResolveException("NZB host is not public")
        }
    }

    fun redirect(
        current: CheckedRequest,
        location: String,
        resolve: (String) -> List<InetAddress> = PublicAddressPolicy::requirePublic,
    ): CheckedRequest = checkedRequest(
        current.url.resolve(location)?.toString()
            ?: throw UsenetLocalResolver.ResolveException("invalid NZB redirect"),
        resolve,
    )

    // JVM policy-test compatibility seams.
    fun checkedUrl(raw: String, resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName) =
        checkedRequest(raw) { resolve(it).toList() }.url.toUrl()

    fun redirect(current: java.net.URL, location: String, resolve: (String) -> Array<InetAddress> = InetAddress::getAllByName) =
        checkedRequest(current.toExternalForm()) { resolve(it).toList() }
            .let { redirect(it, location) { host -> resolve(host).toList() }.url.toUrl() }

    fun readBoundedUtf8(input: InputStream, limit: Int = MAX_BYTES): String {
        val output = ByteArrayOutputStream(minOf(limit, 8 * 1024))
        val buffer = ByteArray(8 * 1024)
        var total = 0
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > limit) throw UsenetLocalResolver.ResolveException("NZB exceeds size limit")
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

}

/**
 * OkHttp-only NZB transport: no system proxy, redirects off, and a custom DNS implementation that returns
 * only the exact answers validated by [NzbFetchPolicy.checkedRequest]. This closes validate/connect rebinding.
 */
internal class PinnedNzbTransport(
    private val timeoutMs: Int,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .followRedirects(false)
        .followSslRedirects(false)
        .build(),
) {
    data class Response(val code: Int, val location: String?, val body: String?)

    suspend fun execute(request: NzbFetchPolicy.CheckedRequest): Response {
        val pinnedDns = dnsFor(request)
        val call = client.newBuilder()
            .dns(pinnedDns)
            .connectTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .readTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .callTimeout(timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .build()
            .newCall(Request.Builder().url(request.url).get().build())
        val cancellationCancel = coroutineContext[Job]?.invokeOnCompletion { call.cancel() }
        try {
            return call.execute().use { response ->
                Response(
                    code = response.code,
                    location = response.header("Location"),
                    body = if (response.isSuccessful) {
                        response.body?.byteStream()?.use(NzbFetchPolicy::readBoundedUtf8)
                    } else null,
                )
            }.also { coroutineContext.ensureActive() }
        } catch (error: IOException) {
            // `Call.cancel()` unblocks OkHttp as an IOException. Preserve cancellation instead of allowing a
            // stale, caller-cancelled NZB request to be reported as a provider failure.
            coroutineContext.ensureActive()
            throw error
        } finally {
            cancellationCancel?.dispose()
        }
    }

    internal fun dnsFor(request: NzbFetchPolicy.CheckedRequest): Dns = object : Dns {
        override fun lookup(hostname: String): List<InetAddress> {
            if (hostname != request.url.host) {
                throw UnknownHostException("Unexpected NZB DNS lookup for $hostname")
            }
            return request.addresses
        }
    }
}
