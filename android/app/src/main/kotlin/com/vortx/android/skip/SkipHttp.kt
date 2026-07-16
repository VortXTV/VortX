package com.vortx.android.skip

import com.vortx.android.net.VortXEdgeAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/// Minimal suspend HTTP helper shared by the skip stack ([SkipTimestampService], [SkipDBClient],
/// [AniSkipService]). Uses `java.net.HttpURLConnection` like [com.vortx.android.person.TMDBPersonClient] /
/// [com.vortx.android.integrations.IntegrationsHttp] rather than pulling in a new networking dependency:
/// the payloads here are tiny skip-timestamp JSON documents, so the platform HTTP stack is enough.
///
/// EVERY request is run through [VortXEdgeAuth.sign] right before send. That call is a NO-OP for any host
/// not in the signer's gated set, so a VortX leg (skip.vortx.tv) gets the `X-VX-*` HMAC headers while a
/// third-party leg (theintrodb.org / skipdb.tv / aniskip.com / kitsu.io / a user's custom mirror) passes
/// through unsigned automatically. This mirrors the Apple split where only the `*.vortx.tv` calls run
/// `VortXEdgeAuth.sign(&request)` and the third-party calls deliberately do not.
///
/// Fail-soft: a transport failure (offline / DNS / TLS / timeout) surfaces as [Result] with status 0 and
/// an empty body (never a thrown network exception), so every caller stays fail-soft exactly like the
/// Apple `try?`-wrapped `URLSession.shared.data(for:)`.
internal object SkipHttp {

    /// Apple sets `timeoutInterval = 5` on the skip READ requests and `10` on the SUBMIT requests. Match.
    const val READ_TIMEOUT_MS = 5_000
    const val SUBMIT_TIMEOUT_MS = 10_000

    /// Status 0 is reserved for a transport failure (no HTTP response reached). A real HTTP status is
    /// passed through untouched so callers can branch on 200 / 404 / 429 / 400 exactly as the Apple code.
    data class Result(val status: Int, val body: String) {
        val isSuccess: Boolean get() = status in 200..299
    }

    /// Perform an HTTP request with an optional JSON [body]. [headers] are set verbatim. Returns the status
    /// + response body (reading the error stream on a non-2xx so an error JSON stays available). Runs on
    /// [Dispatchers.IO]. Signs for gated VortX hosts via [VortXEdgeAuth] (no-op for third-party hosts).
    suspend fun request(
        method: String,
        urlString: String,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
        timeoutMs: Int = READ_TIMEOUT_MS,
    ): Result = withContext(Dispatchers.IO) {
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
            // Stamp X-VX-* for the gated VortX hosts (no-op for third-party hosts), AFTER method + URL are
            // set and BEFORE the body is written / the response is read, per the signer's contract.
            VortXEdgeAuth.sign(connection)
            if (body != null) connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..399) connection.inputStream else connection.errorStream
            val text = stream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
            Result(status, text)
        } catch (_: IOException) {
            // Offline / DNS / TLS / timeout: report a transport failure (status 0) rather than throwing,
            // so a network outage never blocks playback or the skip button.
            Result(0, "")
        } finally {
            connection?.disconnect()
        }
    }
}
