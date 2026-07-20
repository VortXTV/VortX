package com.vortx.android.integrations

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/// Minimal suspend JSON-over-HTTP helper shared by [TraktAuth], [SIMKLAuth], and [ScrobbleService]. Uses
/// `java.net.HttpURLConnection` (like [com.vortx.android.net.VortXEdgeAuth]) rather than pulling in a new
/// networking dependency: the payloads here are tiny OAuth/scrobble JSON documents, so the platform HTTP
/// stack is more than enough. Every call runs on [Dispatchers.IO]; a transport failure surfaces as
/// [Response] with status 0 (never a thrown network exception), so callers stay fail-soft.
internal object IntegrationsHttp {

    private const val TIMEOUT_MS = 20_000

    /// Status 0 is reserved for a transport failure (no HTTP response reached). Any real HTTP status is
    /// passed through untouched so callers can branch on 200/400/401/409/410/418/429 exactly as the
    /// Apple actors do.
    data class Response(val status: Int, val body: String) {
        val isSuccess: Boolean get() = status in 200..299
    }

    /// Perform an HTTP request with an optional JSON [body]. [headers] are set verbatim. Returns the
    /// status + response body (reading the error stream on a non-2xx so an error JSON is still available).
    suspend fun request(
        method: String,
        urlString: String,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
    ): Response = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(urlString).openConnection() as HttpURLConnection).apply {
                requestMethod = method.uppercase()
                connectTimeout = TIMEOUT_MS
                readTimeout = TIMEOUT_MS
                useCaches = false
                headers.forEach { (name, value) -> setRequestProperty(name, value) }
                if (body != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                }
            }
            val status = connection.responseCode
            val stream = if (status in 200..399) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            Response(status, text)
        } catch (_: IOException) {
            // Offline / DNS / TLS / timeout: report a transport failure (status 0) rather than throwing,
            // so a network outage never blocks playback or crashes the auth flow.
            Response(0, "")
        } finally {
            connection?.disconnect()
        }
    }
}
