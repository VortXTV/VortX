package com.vortx.android.imports

import com.vortx.android.engine.PublicAddressPolicy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * Minimal suspend GET-as-text helper for the list-import fetchers. Uses `java.net.HttpURLConnection` (like
 * [com.vortx.android.integrations.IntegrationsHttp] and [com.vortx.android.home.ExternalMetadataResolver])
 * rather than adding a networking dependency; the payloads here are small HTML/JSON list documents.
 *
 * SSRF GUARD (the "carry the AddonURLGuard private/loopback/link-local host check on every fetch" invariant):
 * before any connection, the destination host is validated against the blocked private/loopback/link-local/
 * CGNAT/ULA ranges via [PublicAddressPolicy], the SAME policy the add-on manifest fetch uses
 * (`com.vortx.android.engine.AddonManifestFetcher`) and the Android analogue of Apple `AddonURLGuard`. A
 * literal-IP host is checked directly; a hostname is resolved and every resolved address is checked, failing
 * closed on any blocked one. The list fetchers already build every URL against a FIXED per-provider host
 * (never the pasted host), so this is defense-in-depth on top of that.
 *
 * RESIDUAL RISK (accepted, identical to Apple's `AddonURLGuard` note): this validates then connects with a
 * separate `HttpURLConnection` that re-resolves DNS independently, so the connected IP is not pinned to the
 * validated one. A hostile ~0-TTL authoritative DNS could answer public here and private at connect time
 * (DNS rebinding). Since every fetch targets a fixed public provider host and the body is parsed only as list
 * data (never reflected), this stays a known, accepted limitation, matching the Apple app.
 *
 * FAIL-SOFT: every failure (blocked host, offline, non-2xx, oversize, parse) returns null. Never throws
 * (except it rethrows [CancellationException], never swallowing coroutine cancellation).
 */
internal object ImportHttp {

    private const val TIMEOUT_MS = 20_000

    /** Upper bound for a fetched list document, so a hostile/huge response cannot grow an unbounded buffer. */
    private const val MAX_BYTES = 8 * 1024 * 1024

    /**
     * GET [urlString] as UTF-8 text with the browser UA, after validating the host is public. [headers] are
     * set verbatim (e.g. the Trakt api-key / version). Returns the body, or null on any failure.
     */
    suspend fun fetchText(
        urlString: String,
        headers: Map<String, String> = emptyMap(),
    ): String? = withContext(Dispatchers.IO) {
        val url = runCatching { URL(urlString) }.getOrNull() ?: return@withContext null
        if (url.protocol != "http" && url.protocol != "https") return@withContext null
        if (!url.userInfo.isNullOrEmpty()) return@withContext null
        val host = url.host?.takeIf { it.isNotEmpty() } ?: return@withContext null
        // Private/loopback/link-local guard, on every fetch. Fail closed on any blocked or unresolvable host.
        val hostOk = runCatching {
            PublicAddressPolicy.requireLiteralPublicOrHostname(host)
            PublicAddressPolicy.requirePublic(host)
        }.isSuccess
        if (!hostOk) return@withContext null

        var connection: HttpURLConnection? = null
        try {
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", ListImport.BROWSER_UA)
                setRequestProperty("Accept", "application/json, text/html;q=0.9, */*;q=0.5")
                headers.forEach { (name, value) -> setRequestProperty(name, value) }
            }
            val status = connection.responseCode
            if (status !in 200..299) return@withContext null
            connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                val buffer = CharArray(16 * 1024)
                val out = StringBuilder()
                while (true) {
                    val read = reader.read(buffer)
                    if (read < 0) break
                    if (out.length + read > MAX_BYTES) return@withContext null
                    out.append(buffer, 0, read)
                }
                out.toString()
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: IOException) {
            null
        } catch (_: RuntimeException) {
            // A malformed/oversized header set can surface as an unchecked error from the stack; stay fail-soft.
            null
        } finally {
            connection?.disconnect()
        }
    }
}
