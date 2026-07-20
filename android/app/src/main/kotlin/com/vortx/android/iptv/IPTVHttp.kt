package com.vortx.android.iptv

import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/// Minimal suspend HTTP helper for the hosted IPTV converter, mirroring [com.vortx.android.skip.SkipHttp]
/// and [com.vortx.android.integrations.IntegrationsHttp]: `java.net.HttpURLConnection` (no new networking
/// dependency, the register / revoke payloads are tiny JSON documents) run on [Dispatchers.IO], with every
/// request signed by [VortXEdgeAuth] right before send.
///
/// `iptv.vortx.tv` is in the signer's gated-host set, so [VortXEdgeAuth.sign] stamps the `X-VX-*` HMAC
/// headers on every call here. Signing is a safe no-op that stays observe-safe until the edge secret is
/// provisioned and tightens later with no client change (the SAME split the skip stack uses, and the SAME
/// behaviour the Apple `IPTVConverterClient` gets from `VortXEdgeAuth.sign(&req)`).
///
/// Fail-soft: a transport failure (offline / DNS / TLS / timeout) surfaces as status 0 + empty body, never a
/// thrown exception, so the caller stays fail-soft exactly like the Apple `try? URLSession.shared.data(for:)`.
internal object IPTVHttp {

    /// Apple sets `timeoutInterval = 20` on register and `12` on revoke (IPTVConverterClient.swift). Match.
    const val REGISTER_TIMEOUT_MS = 20_000
    const val REVOKE_TIMEOUT_MS = 12_000

    /// Status 0 is reserved for a transport failure (no HTTP response reached). A real HTTP status passes
    /// through untouched so the caller can branch on 2xx vs the worker's error codes exactly as Apple does.
    data class Response(val status: Int, val body: String) {
        val isSuccess: Boolean get() = status in 200..299
    }

    /// Perform an HTTP request with an optional JSON [body]. [headers] are set verbatim. Returns the status +
    /// response body (reading the error stream on a non-2xx so an error JSON stays available). Runs on
    /// [Dispatchers.IO]; signs the gated VortX host via [VortXEdgeAuth].
    suspend fun request(
        method: String,
        urlString: String,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
        timeoutMs: Int = REGISTER_TIMEOUT_MS,
    ): Response = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = method.uppercase()
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                useCaches = false
                headers.forEach { (name, value) -> setRequestProperty(name, value) }
                if (body != null) {
                    doOutput = true
                    if (!headers.containsKey("Content-Type")) setRequestProperty("Content-Type", "application/json")
                }
            }
            // Stamp X-VX-* for the gated VortX host, AFTER method + URL are set and BEFORE the body is
            // written / the response is read, per the signer's contract.
            VortXEdgeAuth.sign(connection)
            if (body != null) connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..399) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            Response(status, text)
        } catch (_: IOException) {
            // Offline / DNS / TLS / timeout: report a transport failure (status 0) rather than throwing, so a
            // network outage never crashes the add-playlist flow.
            Response(0, "")
        } finally {
            connection?.disconnect()
        }
    }
}
