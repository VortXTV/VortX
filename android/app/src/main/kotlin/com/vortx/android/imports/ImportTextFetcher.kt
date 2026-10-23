package com.vortx.android.imports

import com.vortx.android.engine.PublicAddressPolicy
import com.vortx.android.engine.DeadlinePublicDns
import com.vortx.android.engine.buildAddonManifestClient
import kotlinx.coroutines.CancellationException
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.OkHttpClient
import okhttp3.Dns
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/** Redirect policy is shared by the real transport and deterministic no-network tests. */
internal class ImportTextFetcher(
    userAgent: String,
    private val hostValidator: (String) -> Unit = PublicAddressPolicy::requireLiteralPublicOrHostname,
    private val transport: ImportTextTransport = OkHttpImportTextTransport(userAgent),
    private val nanoTime: () -> Long = System::nanoTime,
) {
    fun fetch(urlString: String, headers: Map<String, String> = emptyMap(), followRedirects: Boolean = true,
              checkActive: () -> Unit = {}): String? {
        var current = urlString.toHttpUrlOrNull()?.takeIf(::isAllowed) ?: return null
        val original = current
        val originalHeaders = headers.toMap()
        var carryHeaders = true
        var redirects = 0
        val startedAt = nanoTime()
        try {
            while (true) {
                checkActive()
                val remaining = TimeUnit.MILLISECONDS.toNanos(TIMEOUT_MS) - (nanoTime() - startedAt)
                if (remaining <= 0) return null
                val response = transport.execute(
                    current, if (carryHeaders) originalHeaders else emptyMap(),
                    TimeUnit.NANOSECONDS.toMillis(remaining).coerceAtLeast(1),
                )
                checkActive()
                if (response.statusCode in REDIRECTS) {
                    if (!followRedirects || redirects >= MAX_REDIRECTS) return null
                    val next = response.location?.let(current::resolve)?.takeIf(::isAllowed) ?: return null
                    // List providers start on HTTPS. A redirect must not downgrade their payload or headers.
                    if (current.scheme == "https" && next.scheme != "https") return null
                    carryHeaders = carryHeaders && sameOrigin(original, next)
                    current = next
                    redirects += 1
                    continue
                }
                if (response.statusCode !in 200..299) return null
                val bytes = response.body ?: return null
                if (bytes.size > MAX_BYTES) return null
                return bytes.toString(Charsets.UTF_8)
            }
        } catch (cancel: CancellationException) {
            throw cancel
        } catch (_: Exception) {
            return null
        }
    }

    private fun isAllowed(url: HttpUrl): Boolean = url.username.isEmpty() && url.password.isEmpty() &&
        runCatching { hostValidator(url.host) }.isSuccess

    private fun sameOrigin(a: HttpUrl, b: HttpUrl): Boolean =
        a.scheme == b.scheme && a.host == b.host && a.port == b.port

    companion object {
        const val MAX_BYTES = 8 * 1024 * 1024
        private const val TIMEOUT_MS = 20_000L
        private const val MAX_REDIRECTS = 5
        private val REDIRECTS = setOf(301, 302, 303, 307, 308)
    }
}

internal fun interface ImportTextTransport {
    fun execute(url: HttpUrl, headers: Map<String, String>, timeoutMs: Long): ImportTextResponse
}

internal data class ImportTextResponse(
    val statusCode: Int,
    val location: String? = null,
    val body: ByteArray? = null,
)

private class OkHttpImportTextTransport(private val userAgent: String) : ImportTextTransport {
    // DNS is resolved and admitted by the connection itself, with no independent second lookup.
    // Redirects/proxies are disabled by this shared builder.
    private val client = buildAddonManifestClient(20_000)
    override fun execute(url: HttpUrl, headers: Map<String, String>, timeoutMs: Long): ImportTextResponse {
        val request = Request.Builder().url(url)
            .header("User-Agent", userAgent)
            .header("Accept", "application/json, text/html;q=0.9, */*;q=0.5")
            .apply { headers.forEach { (name, value) -> header(name, value) } }.get().build()
        val call = importTextRequestClient(client, timeoutMs).newCall(request)
        call.timeout().timeout(timeoutMs, TimeUnit.MILLISECONDS)
        return call.execute().use { response ->
            val body = response.body
            ImportTextResponse(response.code, response.header("Location"),
                if (response.isSuccessful && body != null && body.contentLength() <= ImportTextFetcher.MAX_BYTES)
                    body.byteStream().use(::readLimitedImportBytes) else null)
        }
    }
}

/** A later hop's DNS lookup shares the remaining chain budget, including a resolver which
 * ignores interruption. The base client retains its connection pool and no-proxy policy. */
internal fun importTextRequestClient(
    base: OkHttpClient,
    timeoutMs: Long,
    resolver: (String) -> List<InetAddress> = PublicAddressPolicy::requirePublic,
): OkHttpClient = base.newBuilder().dns(ImportDeadlineDns(timeoutMs, resolver)).build()

/** OkHttp includes DNS equality in a connection's Address. A deadline varies per request but
 * does not change which public addresses the resolver admits. Equal policies can reuse an
 * already-admitted socket; a new socket still resolves through its own remaining deadline. */
private class ImportDeadlineDns(
    timeoutMs: Long,
    private val resolver: (String) -> List<InetAddress>,
) : Dns {
    private val delegate = DeadlinePublicDns(timeoutMs, resolver)
    override fun lookup(hostname: String): List<InetAddress> = delegate.lookup(hostname)
    override fun equals(other: Any?): Boolean = other is ImportDeadlineDns && resolver == other.resolver
    override fun hashCode(): Int = resolver.hashCode()
}

/** Limit bytes before decoding UTF-8: a character count is not a response-byte bound. */
internal fun readLimitedImportBytes(input: InputStream): ByteArray? {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    while (true) {
        val count = input.read(buffer)
        if (count < 0) return out.toByteArray()
        if (out.size() + count > ImportTextFetcher.MAX_BYTES) return null
        out.write(buffer, 0, count)
    }
}
