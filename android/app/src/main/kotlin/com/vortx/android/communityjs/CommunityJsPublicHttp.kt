package com.vortx.android.communityjs

import com.vortx.android.engine.DeadlinePublicDns
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.OkHttpClient
import java.io.ByteArrayOutputStream
import java.net.Proxy
import java.util.concurrent.TimeUnit

/**
 * Request-time public-network transport for executable manifests and provider requests.
 *
 * Redirects are intentionally followed here rather than by OkHttp: every hop is reparsed and
 * admitted, while [DeadlinePublicDns] returns only public addresses to the actual connection.
 */
internal object CommunityJsPublicHttp {
    fun fetch(
        rawUrl: String,
        requireHttps: Boolean,
        headers: Map<String, String> = emptyMap(),
        method: String = "GET",
        body: String? = null,
        timeoutMs: Long,
        maxBytes: Int,
    ): ResponseData? {
        val root = CommunityJsHttpPolicy.admit(rawUrl)?.takeIf { !requireHttps || it.isHttps } ?: return null
        var current = root
        var currentMethod = method.uppercase()
        var currentBody = body?.toByteArray(Charsets.UTF_8)
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(1))
        repeat(MAX_REDIRECTS + 1) {
            val remainingMs = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime()).coerceAtLeast(1)
            val client = baseClient(remainingMs)
            val request = Request.Builder().url(current).apply {
                CommunityJsHttpPolicy.requestHeaders(root, current, headers).forEach { (name, value) -> header(name, value) }
                method(currentMethod, currentBody?.toRequestBody())
            }.build()
            val response = runCatching {
                client.newCall(request).also { call -> call.timeout().timeout(remainingMs, TimeUnit.MILLISECONDS) }.execute()
            }.getOrNull() ?: return null
            response.use { currentResponse ->
                if (currentResponse.code in REDIRECTS) {
                    val location = currentResponse.header("Location") ?: return null
                    val transition = CommunityJsHttpPolicy.redirect(
                        root, current, location, currentResponse.code, currentMethod, currentBody,
                    ) ?: return null
                    if (requireHttps && !transition.url.isHttps) return null
                    current = transition.url
                    currentMethod = transition.method
                    currentBody = transition.body
                    return@repeat
                }
                return ResponseData(
                    status = currentResponse.code,
                    statusText = currentResponse.message,
                    headers = currentResponse.headers.names().associateWith { currentResponse.header(it).orEmpty() },
                    body = currentResponse.readLimitedUtf8(maxBytes) ?: return null,
                )
            }
        }
        return null
    }

    private fun baseClient(timeoutMs: Long): OkHttpClient = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .dns(DeadlinePublicDns(timeoutMs))
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .build()

    private fun Response.readLimitedUtf8(limit: Int): String? {
        val input = body?.byteStream() ?: return ""
        return input.use {
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val read = it.read(buffer)
                if (read < 0) break
                total += read
                if (total > limit) return null
                output.write(buffer, 0, read)
            }
            output.toString(Charsets.UTF_8.name())
        }
    }

    data class ResponseData(val status: Int, val statusText: String, val headers: Map<String, String>, val body: String)

    private const val MAX_REDIRECTS = 5
    private val REDIRECTS = setOf(301, 302, 303, 307, 308)
}
