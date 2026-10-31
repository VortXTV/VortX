package com.vortx.android.engine

import com.vortx.android.cast.CastEligibility
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.Proxy
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import org.json.JSONObject

/** Same /settings and /{hash}/create contract used by the Apple and in-process server clients. */
object StreamingServerTransport {
    private const val MAX_SETTINGS_BYTES = 64 * 1024
    private const val MAX_CREATE_BYTES = 1024 * 1024
    private val client = OkHttpClient.Builder()
        .proxy(Proxy.NO_PROXY).followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .connectTimeout(6, TimeUnit.SECONDS).callTimeout(6, TimeUnit.SECONDS)
        .dns(Dns { host ->
            // A user-selected LAN/Tailscale host may resolve privately, but never to a metadata,
            // loopback, link-local or ambiguous endpoint. Normal TLS verification remains enabled.
            Dns.SYSTEM.lookup(host).also { addresses ->
                if (addresses.isEmpty() || addresses.any { address ->
                        val numeric = address.hostAddress.orEmpty()
                        val rendered = if (':' in numeric) "[$numeric]" else numeric
                        !CastEligibility.isRemoteHttpUrl("http://$rendered/")
                    }) throw IOException("Streaming server address is unavailable")
            }
        }).build()

    private val createClient = client.newBuilder().readTimeout(75, TimeUnit.SECONDS).callTimeout(75, TimeUnit.SECONDS).build()

    suspend fun probe(raw: String): Boolean {
        val base = StreamingServerSelection.normalizedBase(raw) ?: return false
        return try {
            val response = execute(client, Request.Builder().url("$base/settings").build(), MAX_SETTINGS_BYTES)
            acceptsSettings(response.first, response.second)
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) { false }
    }

    internal fun acceptsSettings(status: Int, bytes: ByteArray): Boolean = status == 200 &&
        boundedObject(bytes, MAX_SETTINGS_BYTES)?.opt("values") is JSONObject

    internal suspend fun prepare(selection: ChosenStreamingServer, infoHash: String, fileIndex: Int): StreamingServerPreparedFile {
        require(Regex("[a-f0-9]{40}").matches(infoHash))
        if (!selection.isCurrent()) throw CancellationException("Streaming server choice changed")
        val body = JSONObject().put("torrent", JSONObject().put("infoHash", infoHash)).toString()
        val (status, bytes) = try {
            execute(createClient, Request.Builder().url("${selection.base}/$infoHash/create")
                .post(body.toRequestBody("application/json".toMediaType())).build(), MAX_CREATE_BYTES, selection)
        } catch (error: Exception) {
            if (!selection.isCurrent()) throw CancellationException("Streaming server choice changed")
            throw error
        }
        val file = checkNotNull(preparedFile(status, bytes, infoHash, fileIndex)) {
            "Streaming server could not prepare the selected torrent file"
        }
        if (!selection.isCurrent()) throw CancellationException("Streaming server choice changed")
        return file
    }

    internal fun preparedFile(status: Int, bytes: ByteArray, infoHash: String, fileIndex: Int): StreamingServerPreparedFile? {
        if (status !in 200..299 || bytes.size > MAX_CREATE_BYTES || fileIndex < 0) return null
        return try {
            val result = boundedObject(bytes, MAX_CREATE_BYTES) ?: return null
            if (!(result.opt("infoHash") as? String).equals(infoHash, ignoreCase = true)) return null
            val files = result.optJSONArray("files") ?: return null
            val file = files.optJSONObject(fileIndex) ?: return null
            val name = (file.opt("name") as? String)?.takeIf { it.isNotBlank() && it.length <= 4096 && '\u0000' !in it } ?: return null
            val length: Long = when (val value = file.opt("length")) {
                is Int -> value.toLong()
                is Long -> value
                else -> return null
            }
            if (length <= 0) return null
            StreamingServerPreparedFile(name)
        } catch (_: Exception) { null }
    }

    /** Preflight before the platform's recursive JSONObject parser; never recover from stack exhaustion. */
    private fun boundedObject(bytes: ByteArray, maxBytes: Int): JSONObject? {
        if (bytes.isEmpty() || bytes.size > maxBytes) return null
        return try {
            val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
            if (!boundedObjectFrame(text)) return null
            JSONObject(text)
        } catch (_: Exception) { null }
    }

    /** Iterative, string-aware JSON framing only. JSONObject still constructs and types the values. */
    private fun boundedObjectFrame(text: String): Boolean {
        val maxDepth = 32
        val maxNodes = 50_000
        // Object: first key/end, required key, colon, value, separator/end.
        // Array: first value/end, required value, separator/end.
        val objectFirst = 0; val objectKey = 1; val objectColon = 2; val objectValue = 3; val objectAfter = 4
        val arrayFirst = 5; val arrayValue = 6; val arrayAfter = 7
        val states = IntArray(maxDepth)
        var depth = 0
        var index = 0
        var nodes = 0
        fun whitespace() { while (index < text.length && text[index] in " \t\r\n") index++ }
        fun node(): Boolean { nodes++; return nodes <= maxNodes }
        fun string(): Boolean {
            if (index >= text.length || text[index++] != '"') return false
            while (index < text.length) {
                val ch = text[index++]
                if (ch == '"') return true
                if (ch < ' ') return false
                if (ch == '\\') {
                    if (index >= text.length) return false
                    when (text[index++]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                        'u' -> {
                            if (index + 4 > text.length) return false
                            repeat(4) {
                                val hex = text[index++]
                                if (hex !in '0'..'9' && hex !in 'a'..'f' && hex !in 'A'..'F') return false
                            }
                        }
                        else -> return false
                    }
                }
            }
            return false
        }
        fun value(): Boolean {
            if (index >= text.length || !node()) return false
            return when (text[index]) {
                '{', '[' -> {
                    if (depth == maxDepth) false else {
                        states[depth++] = if (text[index++] == '{') objectFirst else arrayFirst
                        true
                    }
                }
                '"' -> string()
                else -> {
                    val start = index
                    while (index < text.length && text[index] !in " \t\r\n,]}") index++
                    val count = index - start
                    if (count !in 1..128) false else {
                        val token = text.substring(start, index)
                        token == "true" || token == "false" || token == "null" || JSON_NUMBER.matches(token)
                    }
                }
            }
        }
        whitespace()
        if (index >= text.length || text[index] != '{' || !value()) return false
        while (depth > 0) {
            whitespace()
            if (index >= text.length) return false
            val top = depth - 1
            when (states[top]) {
                objectFirst, objectKey -> {
                    if (states[top] == objectFirst && text[index] == '}') { index++; depth-- }
                    else {
                        if (!node() || !string()) return false
                        states[top] = objectColon
                    }
                }
                objectColon -> {
                    if (text[index++] != ':') return false
                    states[top] = objectValue
                }
                objectValue -> {
                    states[top] = objectAfter
                    if (!value()) return false
                }
                objectAfter -> when (text[index++]) {
                    ',' -> states[top] = objectKey
                    '}' -> depth--
                    else -> return false
                }
                arrayFirst, arrayValue -> {
                    if (states[top] == arrayFirst && text[index] == ']') { index++; depth-- }
                    else {
                        states[top] = arrayAfter
                        if (!value()) return false
                    }
                }
                arrayAfter -> when (text[index++]) {
                    ',' -> states[top] = arrayValue
                    ']' -> depth--
                    else -> return false
                }
                else -> return false
            }
        }
        whitespace()
        return index == text.length
    }

    private val JSON_NUMBER = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

    /** Cancellation cancels this exact Call, including a bounded response-body read. No retry or redirect. */
    private suspend fun execute(http: OkHttpClient, request: Request, maxBytes: Int,
        selection: ChosenStreamingServer? = null): Pair<Int, ByteArray> = suspendCancellableCoroutine { continuation ->
        val call = http.newCall(request)
        val retirement = selection?.onRetire { call.cancel() }
        continuation.invokeOnCancellation { retirement?.close(); call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, error: IOException) {
                retirement?.close()
                if (continuation.isActive)
                    continuation.resumeWithException(IOException("Streaming server request failed"))
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val result = response.use {
                        val bytes = ByteArrayOutputStream()
                        val input = it.body?.byteStream()
                        if (input != null) {
                            val chunk = ByteArray(8192)
                            while (true) {
                                val count = input.read(chunk)
                                if (count < 0) break
                                check(bytes.size() + count <= maxBytes) { "Streaming server response exceeds limit" }
                                bytes.write(chunk, 0, count)
                            }
                        }
                        it.code to bytes.toByteArray()
                    }
                    if (continuation.isActive) continuation.resume(result)
                } catch (_: Exception) {
                    if (continuation.isActive)
                        continuation.resumeWithException(IOException("Streaming server response failed"))
                } finally {
                    retirement?.close()
                }
            }
        })
    }
}

/** MIME follows the selected file returned by the real server, not the extensionless hash route. */
internal class StreamingServerPreparedFile(name: String) {
    internal val contentType: String? = when (name.substringAfterLast('.', "").lowercase()) {
        "mp4", "m4v" -> "video/mp4"
        "mkv" -> "video/x-matroska"
        "webm" -> "video/webm"
        "mov" -> "video/quicktime"
        "ts", "m2ts" -> "video/mp2t"
        "mpg", "mpeg" -> "video/mpeg"
        "avi" -> "video/x-msvideo"
        "wmv" -> "video/x-ms-wmv"
        else -> null
    }
    override fun toString(): String = "StreamingServerPreparedFile(<selected media>)"
}
