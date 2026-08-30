package com.vortx.android.communityjs

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import com.vortx.android.engine.DeadlinePublicDns
import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.io.InputStream
import java.net.Proxy
import java.util.concurrent.TimeUnit

/** Connection-time public-DNS and exact-origin credential transport for Community-JS Media3 loads. */
@UnstableApi
internal class CommunityJsMedia3DataSourceFactory(
    rootUrl: String,
    providerHeaders: Map<String, String>,
    private val timeoutMs: Long = 30_000L,
) : DataSource.Factory {
    private val root = requireNotNull(CommunityJsHttpPolicy.admit(rootUrl)) { "Invalid Community-JS URL" }
    private val headers = providerHeaders.toMap()

    override fun createDataSource(): DataSource = CommunityJsMedia3DataSource(root, headers, timeoutMs)
}

@UnstableApi
private class CommunityJsMedia3DataSource(
    private val root: HttpUrl,
    private val providerHeaders: Map<String, String>,
    private val timeoutMs: Long,
) : BaseDataSource(true) {
    private val client = okhttp3.OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY)
        .dns(DeadlinePublicDns(timeoutMs))
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .readTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .callTimeout(timeoutMs, TimeUnit.MILLISECONDS)
        .build()
    private var response: Response? = null
    private var input: InputStream? = null
    private var opened = false
    private var currentUri: Uri? = null
    private var remaining = C.LENGTH_UNSET.toLong()

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        var current = CommunityJsHttpPolicy.admit(dataSpec.uri.toString()) ?: throw IOException("Blocked Community-JS URL")
        if (dataSpec.length == 0L) {
            currentUri = dataSpec.uri
            remaining = 0L
            opened = true
            transferStarted(dataSpec)
            return 0L
        }
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs.coerceAtLeast(1L))
        var method = when (dataSpec.httpMethod) {
            DataSpec.HTTP_METHOD_POST -> "POST"
            DataSpec.HTTP_METHOD_HEAD -> "HEAD"
            else -> "GET"
        }
        var body = dataSpec.httpBody
        repeat(MAX_REDIRECTS + 1) { hop ->
            val request = Request.Builder().url(current).apply {
                val scoped = CommunityJsHttpPolicy.requestHeaders(root, current, providerHeaders) +
                    CommunityJsHttpPolicy.transportHeaders(dataSpec.httpRequestHeaders)
                scoped.forEach { (name, value) -> header(name, value) }
                if (dataSpec.position != 0L || dataSpec.length != C.LENGTH_UNSET.toLong()) {
                    val end = if (dataSpec.length == C.LENGTH_UNSET.toLong()) "" else (dataSpec.position + dataSpec.length - 1).toString()
                    header("Range", "bytes=${dataSpec.position}-$end")
                }
                method(method, body?.toRequestBody())
            }.build()
            val remainingTimeoutMs = TimeUnit.NANOSECONDS.toMillis(deadlineNanos - System.nanoTime())
            if (remainingTimeoutMs <= 0L) throw IOException("Community-JS request timed out")
            val call = client.newCall(request)
            call.timeout().timeout(remainingTimeoutMs, TimeUnit.MILLISECONDS)
            val next = call.execute()
            if (next.code in REDIRECTS) {
                val transition = CommunityJsHttpPolicy.redirect(
                    root, current, next.header("Location") ?: "", next.code, method, body,
                )
                next.close()
                if (transition == null || hop == MAX_REDIRECTS) throw IOException("Blocked Community-JS redirect")
                current = transition.url
                method = transition.method
                body = transition.body
                return@repeat
            }
            if (!next.isSuccessful) { val code = next.code; next.close(); throw IOException("HTTP $code") }
            val responseLength = next.body?.contentLength()?.takeIf { it >= 0L } ?: C.LENGTH_UNSET.toLong()
            val skipBytes = when {
                dataSpec.position == 0L -> 0L
                next.code == 206 -> {
                    val rangeStart = next.header("Content-Range")?.let(CONTENT_RANGE_START::find)
                        ?.groupValues?.getOrNull(1)?.toLongOrNull()
                    if (rangeStart != dataSpec.position) { next.close(); throw IOException("Invalid HTTP range response") }
                    0L
                }
                next.code == 200 -> dataSpec.position
                else -> { next.close(); throw IOException("Invalid HTTP range response") }
            }
            response = next
            input = next.body?.byteStream()
            currentUri = Uri.parse(current.toString())
            remaining = when {
                dataSpec.length != C.LENGTH_UNSET.toLong() -> dataSpec.length
                responseLength != C.LENGTH_UNSET.toLong() -> (responseLength - skipBytes).coerceAtLeast(0L)
                else -> C.LENGTH_UNSET.toLong()
            }
            opened = true
            transferStarted(dataSpec)
            if (skipBytes > 0L) skipFully(skipBytes)
            return remaining
        }
        throw IOException("Too many redirects")
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val count = input?.read(buffer, offset, if (remaining == C.LENGTH_UNSET.toLong()) length else minOf(length.toLong(), remaining).toInt())
            ?: C.RESULT_END_OF_INPUT
        if (count < 0) return C.RESULT_END_OF_INPUT
        if (remaining != C.LENGTH_UNSET.toLong()) remaining -= count
        bytesTransferred(count)
        return count
    }

    override fun getUri(): Uri? = currentUri
    override fun getResponseHeaders(): Map<String, List<String>> = response?.headers?.toMultimap().orEmpty()

    override fun close() {
        runCatching { input?.close() }
        response?.close()
        input = null
        response = null
        currentUri = null
        if (opened) { opened = false; transferEnded() }
    }

    private fun skipFully(byteCount: Long) {
        var skipped = 0L
        val buffer = ByteArray(8 * 1024)
        while (skipped < byteCount) {
            val read = input?.read(buffer, 0, minOf(buffer.size.toLong(), byteCount - skipped).toInt()) ?: -1
            if (read < 0) throw IOException("Unexpected end of response while seeking")
            skipped += read
            bytesTransferred(read)
        }
    }

    private companion object {
        const val MAX_REDIRECTS = 5
        val REDIRECTS = setOf(301, 302, 303, 307, 308)
        val CONTENT_RANGE_START = Regex("^bytes\\s+(\\d+)-", RegexOption.IGNORE_CASE)
    }
}
