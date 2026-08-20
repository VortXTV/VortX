package com.vortx.android.communityjs

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Bounded QuickJS host for one CommonJS provider invocation.
 *
 * The only host capability is [NativeFetch.fetch]. It returns serialized response data, never a Java object,
 * and the script wrapper reconstructs the small browser-like response contract. A fresh QuickJS context is
 * created per invocation and deterministically destroyed by native code before the result leaves this class.
 */
class CommunityJsRuntime(
    private val timeoutMs: Long = DEFAULT_TIMEOUT_MS,
    private val maxResultCount: Int = MAX_RESULT_COUNT,
) {
    data class Invocation(
        val provider: CommunityJsProviderStore.Provider,
        val tmdbId: String,
        val mediaType: String,
        val season: Int?,
        val episode: Int?,
        val settingsJson: String = "{}",
    )

    data class ProviderStream(
        val name: String?,
        val title: String?,
        val url: String,
        val quality: String?,
        val size: String?,
        val headers: Map<String, String>,
        val subtitles: List<Subtitle>,
    )

    data class Subtitle(val url: String, val language: String?, val name: String?, val headers: Map<String, String>)

    sealed interface Result {
        data class Success(val streams: List<ProviderStream>) : Result
        data class Failure(val message: String) : Result
    }

    suspend fun execute(invocation: Invocation): Result {
        if (invocation.provider.code.toByteArray().size > MAX_SOURCE_BYTES) return Result.Failure("Provider source exceeds the limit.")
        if (invocation.mediaType !in setOf("movie", "tv") || invocation.tmdbId.toIntOrNull() == null) return Result.Failure("Invalid media identity.")
        val host = NativeFetchImpl(timeoutMs)
        val cancellation = currentCoroutineContext()[Job]?.invokeOnCompletion { cause ->
            if (cause is CancellationException) host.cancel()
        }
        return try {
            withContext(Dispatchers.Default) { evaluate(invocation, host) }
        } finally {
            cancellation?.dispose()
        }
    }

    private fun evaluate(invocation: Invocation, host: NativeFetchImpl): Result = runCatching {
        val output = CommunityJsNative.evaluate(
            host = host,
            code = invocation.provider.code,
            tmdbId = invocation.tmdbId,
            mediaType = invocation.mediaType,
            season = invocation.season ?: 0,
            episode = invocation.episode ?: 0,
            timeoutMs = timeoutMs,
            memoryLimitBytes = MAX_MEMORY_BYTES,
        )
        val envelope = JSONObject(output)
        if (!envelope.optBoolean("ok")) return Result.Failure(envelope.optString("error", "Provider execution failed."))
        decodeStreams(envelope.optJSONArray("payload")?.toString() ?: "[]")
    }.getOrElse { Result.Failure("Provider execution failed.") }

    /** The single native capability. No filesystem, reflection, application object, or credential bridge is bound. */
    interface NativeFetch {
        fun fetch(url: String, optionsJson: String, remainingTimeoutMs: Long): String
        fun isCancelled(): Boolean
    }

    private class NativeFetchImpl(private val invocationTimeoutMs: Long) : NativeFetch {
        private var requestCount = 0
        @Volatile private var cancelled = false

        fun cancel() { cancelled = true }

        override fun isCancelled(): Boolean = cancelled

        override fun fetch(url: String, optionsJson: String, remainingTimeoutMs: Long): String {
            if (++requestCount > MAX_REQUEST_COUNT) return responseJson(0, "Request limit reached", "", emptyMap())
            if (!CommunityJsUrlPolicy.isPublicHttpUrl(url)) return responseJson(0, "Blocked URL", "", emptyMap())
            val options = runCatching { JSONObject(optionsJson) }.getOrDefault(JSONObject())
            val request = runCatching {
                val headers = options.optJSONObject("headers") ?: JSONObject()
                val builder = Request.Builder().url(url)
                val keys = headers.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    builder.header(key, headers.optString(key))
                }
                if (headers.optString("User-Agent").isBlank()) builder.header("User-Agent", USER_AGENT)
                val method = options.optString("method", "GET").uppercase()
                val bodyText = options.optString("body", "")
                val body = if (method in setOf("POST", "PUT", "PATCH", "DELETE")) bodyText.toRequestBody(null) else null
                builder.method(method, body).build()
            }.getOrNull() ?: return responseJson(0, "Invalid request", "", emptyMap())
            return runCatching {
                http.newCall(request).also { call ->
                    call.timeout().timeout(minOf(invocationTimeoutMs, remainingTimeoutMs).coerceAtLeast(1), TimeUnit.MILLISECONDS)
                }.execute().use { response ->
                    val bodyBuffer = Buffer()
                    var total = 0L
                    response.body?.source()?.use { source ->
                        while (total <= MAX_RESPONSE_BYTES) {
                            val read = source.read(bodyBuffer, MAX_RESPONSE_BYTES.toLong() + 1 - total)
                            if (read < 0) break
                            total += read
                        }
                    }
                    if (total > MAX_RESPONSE_BYTES) return responseJson(0, "Response exceeds the limit", "", emptyMap())
                    val text = bodyBuffer.readString(Charsets.UTF_8)
                    val responseHeaders = buildMap { response.headers.names().forEach { put(it, response.header(it).orEmpty()) } }
                    responseJson(response.code, response.message, text, responseHeaders)
                }
            }.getOrElse { responseJson(0, "Network error", "", emptyMap()) }
        }
    }

    private fun decodeStreams(raw: String): Result {
        val array = runCatching { JSONArray(raw) }.getOrNull() ?: return Result.Failure("Provider result is not an array.")
        val streams = buildList {
            for (i in 0 until minOf(array.length(), maxResultCount)) {
                val item = array.optJSONObject(i) ?: continue
                val url = item.optString("url").trim()
                if (!CommunityJsUrlPolicy.isPublicHttpUrl(url)) continue
                add(ProviderStream(
                    name = item.optString("name").trim().ifEmpty { null },
                    title = item.optString("title").trim().ifEmpty { null },
                    url = url,
                    quality = item.optString("quality").trim().ifEmpty { null },
                    size = item.opt("size")?.toString()?.trim()?.ifEmpty { null },
                    headers = strings(item.optJSONObject("headers")),
                    subtitles = subtitles(item.optJSONArray("subtitles")),
                ))
            }
        }
        return Result.Success(streams)
    }

    private fun subtitles(array: JSONArray?): List<Subtitle> = buildList {
        if (array == null) return@buildList
        for (i in 0 until minOf(array.length(), MAX_SUBTITLE_COUNT)) {
            val item = array.optJSONObject(i) ?: continue
            val url = item.optString("url").trim()
            if (CommunityJsUrlPolicy.isPublicHttpUrl(url)) add(Subtitle(url, item.optString("language").ifBlank { null }, item.optString("name").ifBlank { null }, strings(item.optJSONObject("headers"))))
        }
    }

    private fun strings(json: JSONObject?): Map<String, String> = buildMap {
        val keys = json?.keys() ?: return@buildMap
        while (keys.hasNext()) {
            val key = keys.next()
            val value = json.opt(key)?.toString()?.takeIf { it.length <= 4096 } ?: continue
            if (key.length <= 256) put(key, value)
        }
    }

    companion object {
        private const val DEFAULT_TIMEOUT_MS = 25_000L
        private const val MAX_SOURCE_BYTES = 1_000_000
        private const val MAX_RESPONSE_BYTES = 1_000_000
        private const val MAX_RESULT_COUNT = 100
        private const val MAX_SUBTITLE_COUNT = 20
        private const val MAX_REQUEST_COUNT = 20
        private const val MAX_MEMORY_BYTES = 16L * 1024 * 1024
        private const val USER_AGENT = "Mozilla/5.0 (Android) AppleWebKit/537.36 Chrome/125 Safari/537.36"
        private val http = OkHttpClient.Builder().callTimeout(DEFAULT_TIMEOUT_MS, TimeUnit.MILLISECONDS).build()
        private fun responseJson(status: Int, statusText: String, body: String, headers: Map<String, String>): String = JSONObject().apply {
            put("status", status); put("statusText", statusText); put("body", body); put("headers", JSONObject(headers))
        }.toString()
    }
}
