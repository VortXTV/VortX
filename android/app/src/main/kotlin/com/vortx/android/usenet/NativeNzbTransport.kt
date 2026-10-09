package com.vortx.android.usenet

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.Proxy
import java.net.URI
import java.util.UUID
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class NativeNzbPlayback(val url: String, val lease: AutoCloseable, val isLocal: Boolean = true) {
    override fun toString(): String = "NativeNzbPlayback(<local lease>)"
}

/** Credential control is literal-loopback, proxy-free and redirect-free, including the capability probe. */
internal class NativeNzbTransport(
    private val serverBase: suspend () -> String?,
    client: OkHttpClient = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false)
        .connectTimeout(4, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS)
        .callTimeout(24, TimeUnit.SECONDS).build(),
) {
    private val client = client.newBuilder().proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false).build()
    class Unavailable : IllegalStateException("Native NZB transport is unavailable")

    data class Selection(val fileIdx: Int? = null, val fileMustInclude: String? = null,
        val season: Int? = null, val episode: Int? = null) {
        fun appendTo(value: JSONObject): JSONObject {
            require(fileIdx == null || fileIdx >= 0) { "Invalid NZB file selection" }
            require(fileMustInclude == null || fileMustInclude.toByteArray(Charsets.UTF_8).size <= 512) { "Invalid NZB file selection" }
            require((season == null) == (episode == null) && (season == null || season in 0..9999) &&
                (episode == null || episode in 1..9999)) { "Invalid NZB episode selection" }
            fileIdx?.let { value.put("fileIdx", it) }
            fileMustInclude?.let { value.put("fileMustInclude", it) }
            season?.let { value.put("episode", JSONObject().put("season", it).put("episode", episode)) }
            return value
        }
        override fun toString(): String = "Selection(<NZB media constraints>)"
    }

    suspend fun create(
        mirrors: List<String>, servers: List<String>, timeoutMs: Long,
        selection: Selection = Selection(),
        playbackIsCurrent: (() -> Boolean)? = null,
        isCurrent: () -> Boolean,
    ): NativeNzbPlayback {
        require(timeoutMs > 0) { "Invalid NZB deadline" }
        val urls = NativeNzbInputs.mirrors(null, mirrors)
        val providers = NativeNzbInputs.servers(servers)
        require(urls.isNotEmpty() && providers.isNotEmpty()) { "NZB transport inputs are missing" }
        val payload = selection.appendTo(JSONObject().put("servers", JSONArray(providers)).put("nzbUrls", JSONArray(urls)))
        val admission = { isCurrent() && (playbackIsCurrent?.invoke() ?: true) }
        var operation: Operation? = null
        try {
            // Keep the operation lease even if withContext discards a late return on cancellation.
            return withTimeout(timeoutMs) {
                withContext(Dispatchers.IO) {
                    checkCurrent(admission)
                    val base = localBase(serverBase() ?: throw Unavailable())
                    checkCurrent(admission)
                    val capability = request(Request.Builder().url("$base/nzb/capabilities").get().build(), 4_000)
                    if (capability.first != 200 || !acceptsCapabilities(capability.second)) throw Unavailable()
                    checkCurrent(admission)
                    val owned = Operation(base, UUID.randomUUID().toString(), playbackIsCurrent ?: isCurrent).also { operation = it }
                    payload.put("operationId", owned.id)
                    val response = request(Request.Builder().url("$base/nzb/create")
                        .post(payload.toString().toRequestBody("application/json".toMediaType())).build(), timeoutMs)
                    if (response.first !in 200..299) throw Unavailable()
                    val key = try { JSONObject(response.second).opt("key") as? String } catch (_: Exception) { null }
                    // Rust keys are opaque random lowercase hex. Never accept another URL or path from the response.
                    if (key == null || !key.matches(Regex("[a-f0-9]{32}"))) throw Unavailable()
                    checkCurrent(admission)
                    NativeNzbPlayback("$base/nzb/stream?key=$key", owned)
                }
            }
        } catch (_: TimeoutCancellationException) {
            operation?.close()
            // Our own attempt deadline is a route failure; a canceled caller/owner must stay terminal.
            currentCoroutineContext().ensureActive()
            throw Unavailable()
        } catch (cancel: CancellationException) {
            operation?.close()
            throw cancel
        } catch (_: Exception) {
            operation?.close()
            // No provider URL, credential JSON, response body, or underlying exception escapes diagnostics.
            throw Unavailable()
        }
    }

    /** Cancels precisely this request, including unknown/pending creates; never stops the shared server. */
    private inner class Operation(private val base: String, val id: String,
        playbackIsCurrent: () -> Boolean) : AutoCloseable {
        private val closed = AtomicBoolean(false)
        private val lifetime = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        init {
            lifetime.launch {
                while (isActive) {
                    delay(100)
                    if (!runCatching(playbackIsCurrent).getOrDefault(false)) { close(); return@launch }
                }
            }
        }
        override fun close() {
            if (!closed.compareAndSet(false, true)) return
            lifetime.cancel()
            cancel(attempt = 0)
        }
        private fun cancel(attempt: Int) {
            val call = client.newCall(Request.Builder().url("$base/nzb/operations/$id/cancel")
                .post(ByteArray(0).toRequestBody(null)).build())
            call.timeout().timeout(5, TimeUnit.SECONDS)
            // Idempotent UUID tombstone allows bounded retries, including response-loss after successful cancel.
            // No global server stop and no provider credentials in this request or its diagnostics.
            runCatching {
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) { if (attempt < 2) cancel(attempt + 1) }
                    override fun onResponse(call: Call, response: Response) {
                        val accepted = response.use { it.code == 204 }
                        if (!accepted && attempt < 2) cancel(attempt + 1)
                    }
                })
            }
        }
        override fun toString(): String = "NativeNzbOperation(<local lease>)"
    }

    private suspend fun request(request: Request, timeoutMs: Long): Pair<Int, String> {
        val call = client.newCall(request)
        call.timeout().timeout(timeoutMs, TimeUnit.MILLISECONDS)
        return suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(Unavailable())
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        val result = response.use {
                            val body = it.body ?: throw Unavailable()
                            val source = body.source()
                            source.request(65_537)
                            if (source.buffer.size > 65_536) throw Unavailable()
                            it.code to source.buffer.readUtf8()
                        }
                        if (continuation.isActive) continuation.resume(result)
                    } catch (_: Exception) {
                        if (continuation.isActive) continuation.resumeWithException(Unavailable())
                    }
                }
            })
        }
    }

    companion object {
        fun localBase(raw: String): String {
            val uri = try { URI(raw) } catch (_: Exception) { throw Unavailable() }
            if (uri.scheme != "http" || uri.host != "127.0.0.1" || uri.port !in 1..65535 ||
                uri.rawUserInfo != null || uri.rawQuery != null || uri.rawFragment != null ||
                uri.rawPath !in listOf("", "/") || uri.rawAuthority != "127.0.0.1:${uri.port}") throw Unavailable()
            return "http://127.0.0.1:${uri.port}"
        }

        fun acceptsCapabilities(raw: String): Boolean = runCatching {
            val value = JSONObject(raw)
            val selection = value.optJSONObject("selection") ?: return@runCatching false
            value.opt("version") == 1 && value.opt("operationCancellation") == true &&
                value.opt("operationIdFormat") == "uuid" &&
                selection.opt("fileIdx") == true && selection.opt("fileMustInclude") == true && selection.opt("episode") == true &&
                selection.opt("fileIdxOrder") == "nzb-media-or-archive-entry-order" &&
                selection.opt("regexSyntax") == "bare-or-js-ims" &&
                value.opt("raw") == true && value.opt("multipartYenc") == true &&
                value.opt("checksumsRequired") == true && value.getJSONArray("archives").let { array ->
                val formats = (0 until array.length()).map { array.get(it) }.toSet()
                formats.containsAll(listOf("rar4-store", "rar5-store", "7z-copy"))
            }
        }.getOrDefault(false)

        private suspend fun checkCurrent(isCurrent: () -> Boolean) {
            currentCoroutineContext().ensureActive()
            if (!isCurrent()) throw CancellationException("Usenet playback owner changed")
        }
    }
}
