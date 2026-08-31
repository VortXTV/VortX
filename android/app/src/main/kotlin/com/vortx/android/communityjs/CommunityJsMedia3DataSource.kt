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

    internal fun admitsForTesting(rawUrl: String): Boolean = CommunityJsHttpPolicy.admit(rawUrl) != null
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
                val scoped = communityJsMedia3RequestHeaders(root, current, providerHeaders, dataSpec.httpRequestHeaders)
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
            val responsePlan = try {
                communityJsMedia3ResponsePlan(
                    position = dataSpec.position,
                    requestedLength = dataSpec.length,
                    responseCode = next.code,
                    contentRange = next.header("Content-Range"),
                    responseLength = responseLength,
                )
            } catch (error: IOException) {
                next.close()
                throw error
            }
            response = next
            input = next.body?.byteStream()
            currentUri = Uri.parse(current.toString())
            remaining = responsePlan.remaining
            opened = true
            transferStarted(dataSpec)
            if (responsePlan.skipBytes > 0L) skipFully(responsePlan.skipBytes)
            return remaining
        }
        throw IOException("Too many redirects")
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val count = input?.read(buffer, offset, if (remaining == C.LENGTH_UNSET.toLong()) length else minOf(length.toLong(), remaining).toInt())
            ?: C.RESULT_END_OF_INPUT
        val readResult = communityJsMedia3ReadResult(count, remaining)
        if (readResult < 0) return readResult
        if (remaining != C.LENGTH_UNSET.toLong()) remaining -= readResult
        bytesTransferred(readResult)
        return readResult
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
    }
}

internal data class CommunityJsMedia3ResponsePlan(
    val skipBytes: Long,
    val remaining: Long,
)

/** Pure response routing used by the datasource and JVM tests without constructing Android [DataSpec]. */
internal fun communityJsMedia3ResponsePlan(
    position: Long,
    requestedLength: Long,
    responseCode: Int,
    contentRange: String?,
    responseLength: Long,
): CommunityJsMedia3ResponsePlan {
    val skipBytes = when {
        position == 0L -> 0L
        responseCode == 206 -> {
            val rangeStart = contentRange?.let(CONTENT_RANGE_START::find)
                ?.groupValues?.getOrNull(1)?.toLongOrNull()
            if (rangeStart != position) throw IOException("Invalid HTTP range response")
            0L
        }
        responseCode == 200 -> position
        else -> throw IOException("Invalid HTTP range response")
    }
    val remaining = when {
        requestedLength != C.LENGTH_UNSET.toLong() -> requestedLength
        responseLength != C.LENGTH_UNSET.toLong() -> (responseLength - skipBytes).coerceAtLeast(0L)
        else -> C.LENGTH_UNSET.toLong()
    }
    return CommunityJsMedia3ResponsePlan(skipBytes, remaining)
}

/** Preserve unknown-length EOF while making a premature finite response an I/O failure. */
internal fun communityJsMedia3ReadResult(bytesRead: Int, remaining: Long): Int {
    if (bytesRead >= 0) return bytesRead
    if (remaining == C.LENGTH_UNSET.toLong()) return C.RESULT_END_OF_INPUT
    throw IOException("Unexpected end of response")
}

/** Provider credentials remain exact-origin scoped while Media3 forwarding is limited to safe headers. */
internal fun communityJsMedia3RequestHeaders(
    root: HttpUrl,
    target: HttpUrl,
    providerHeaders: Map<String, String>,
    media3Headers: Map<String, String>,
): Map<String, String> = CommunityJsHttpPolicy.requestHeaders(root, target, providerHeaders) +
    CommunityJsHttpPolicy.transportHeaders(media3Headers)

private val CONTENT_RANGE_START = Regex("^bytes\\s+(\\d+)-", RegexOption.IGNORE_CASE)
