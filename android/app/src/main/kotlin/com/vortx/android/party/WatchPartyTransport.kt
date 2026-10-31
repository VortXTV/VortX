package com.vortx.android.party

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal interface WatchPartySocket {
    val ready: Deferred<Unit>
    val frames: ReceiveChannel<String>
    fun send(value: JSONObject)
    fun close()
    fun isActive(): Boolean
    fun isOpen(): Boolean
}
internal interface WatchPartyServiceTransport {
    suspend fun post(path: String, bearer: String, body: JSONObject): JSONObject
    fun open(roomId: String, ticket: String): WatchPartySocket
}

/** Dedicated transport: no shared interceptor, cookies, credential cache, retries, or redirects. */
internal class WatchPartyTransport : WatchPartyServiceTransport {
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
        .retryOnConnectionFailure(false).callTimeout(8, TimeUnit.SECONDS).build()
    private val jsonType = "application/json; charset=utf-8".toMediaType()
    override suspend fun post(path: String, bearer: String, body: JSONObject): JSONObject {
        require(validPath(path) && bearer.isNotBlank() && bearer.length <= 8192 && bearer.none { it.code <= 32 || it.code >= 127 })
        val encoded = body.toString().toByteArray(Charsets.UTF_8)
        require(encoded.size <= 2048)
        val request = Request.Builder().url("https://api.vortx.tv/v1/watch-parties$path")
            .header("Authorization", "Bearer $bearer").header("Cache-Control", "no-store")
            .post(encoded.toRequestBody(jsonType)).build()
        return suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(IOException("Watch party connection failed"))
                }
                override fun onResponse(call: Call, response: Response) {
                    try {
                        response.use {
                            require(it.isSuccessful && it.request.url == request.url && it.priorResponse == null)
                            val source = it.body?.source() ?: error("Missing party response")
                            val buffer = okio.Buffer()
                            while (buffer.size <= 65_536) {
                                val count = source.read(buffer, minOf(4096L, 65_537 - buffer.size))
                                if (count == -1L) break
                            }
                            require(buffer.size <= 65_536)
                            val result = JSONObject(buffer.readUtf8())
                            if (continuation.isActive) continuation.resume(result)
                        }
                    } catch (_: Exception) {
                        if (continuation.isActive) continuation.resumeWithException(IOException("Watch party request rejected"))
                    }
                }
            })
        }
    }
    override fun open(roomId: String, ticket: String): Socket {
        require(WatchPartyWire.opaque(roomId) && WatchPartyWire.opaque(ticket))
        val socket = Socket()
        val request = Request.Builder().url("https://api.vortx.tv/v1/watch-parties/$roomId/connect")
            .header("Sec-WebSocket-Protocol", "vortx-party-v1, vortx-ticket.$ticket").build()
        val ws = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (response.code != 101 || response.header("Sec-WebSocket-Protocol") != "vortx-party-v1" ||
                    response.priorResponse != null || response.request.url != request.url) {
                    socket.close(); socket.ready.completeExceptionally(IOException("Party protocol rejected")); return
                }
                socket.ready.complete(Unit)
            }
            override fun onMessage(webSocket: WebSocket, text: String) {
                if (text.length > 12_000 || text.toByteArray(Charsets.UTF_8).size > 12_000 || !socket.frames.trySend(text).isSuccess) socket.close()
            }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { socket.close() }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { socket.close() }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { socket.close() }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                socket.ready.completeExceptionally(IOException("Party connection failed")); socket.close()
            }
        })
        socket.attach(ws)
        return socket
    }
    private fun validPath(path: String): Boolean = path.isEmpty() ||
        Regex("/[A-Za-z0-9_-]{22,128}/(join|ticket|snapshot|leave|renew|revoke-invite)").matches(path)
    internal class Socket : WatchPartySocket {
        override val ready = CompletableDeferred<Unit>()
        override val frames = Channel<String>(24)
        private var ws: WebSocket? = null
        private var closed = false
        @Synchronized fun attach(value: WebSocket) { if (closed) value.cancel() else ws = value }
        @Synchronized override fun isActive(): Boolean = !closed
        @Synchronized override fun isOpen(): Boolean = !closed && ready.isCompleted && !ready.isCancelled
        @Synchronized override fun send(value: JSONObject) {
            check(!closed && ready.isCompleted && !ready.isCancelled)
            val text = value.toString(); require(text.toByteArray(Charsets.UTF_8).size <= 12_000)
            check(ws?.send(text) == true)
        }
        @Synchronized override fun close() {
            closed = true; ws?.cancel(); ws = null; frames.cancel(CancellationException("Party connection closed"))
            if (!ready.isCompleted) ready.completeExceptionally(IOException("Party connection closed"))
        }
    }
}
