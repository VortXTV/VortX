package com.vortx.android.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.Channel as PullSignals
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.takeWhile
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** Account-captured SyncRoom channel, foreground-only 3s fallback, and coalesced catch-up pulls.
 * Socket identity AND the exact authenticated session generation fence every callback/task.
 * No bearer is logged or stored independently of that immutable session lease. */
internal class VortXSyncRealtime(
    private val manager: VortXSyncManager,
    private val scope: CoroutineScope,
    private val wssUrl: String,
    private val socketFactory: ((Request, WebSocketListener) -> WebSocket)? = null,
) {
    private val client by lazy {
        OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS).build()
    }
    private class Channel(val lease: SyncSessionLease) {
        val requests = PullSignals<Unit>(PullSignals.CONFLATED)
        var socket: WebSocket? = null
        var pull: Job? = null
        var keepAlive: Job? = null
        var reconnect: Job? = null
        var poll: Job? = null
        var backoffSeconds = 1L
    }
    private var channel: Channel? = null

    fun start() {
        // Never acquire the auth coordinator while holding the channel monitor: sign-out closes
        // realtime under that coordinator, so the inverse edge would deadlock.
        val lease = manager.captureRealtimeLease() ?: return
        val prior = synchronized(this) { channel }
        if (prior != null && current(prior)) return
        var next: Channel? = null
        // Final outbound admission follows auth → channel, the same order as sign-out.
        manager.admitRealtimeLease(lease) {
            synchronized(this) {
                stopLocked()
                next = Channel(lease).also { channel = it; connectLocked(it); startKeepAliveLocked(it); startPollLocked(it) }
            }
            true
        }
        val opened = next ?: return
        val worker = scope.launch(start = CoroutineStart.LAZY) {
            opened.requests.receiveAsFlow().takeWhile { current(opened) }.collect {
                manager.syncDownForRealtime(opened.lease)
            }
        }
        val admitted = synchronized(this) { if (channel === opened) { opened.pull = worker; true } else false }
        if (admitted) { worker.start(); queuePull(opened) } else worker.cancel()
    }

    fun stop() { synchronized(this) { stopLocked() } }
    fun isActive(): Boolean = synchronized(this) { channel != null }

    private fun stopLocked() {
        val old = channel ?: return
        channel = null // revoke before closing; synchronous/late callbacks have no admission
        old.requests.close()
        old.reconnect?.cancel(); old.keepAlive?.cancel(); old.poll?.cancel(); old.pull?.cancel()
        old.socket?.cancel(); old.socket = null
    }

    private fun current(expected: Channel): Boolean =
        synchronized(this) { channel === expected } && manager.isRealtimeLeaseCurrent(expected.lease)

    private fun connectLocked(expected: Channel) {
        val request = Request.Builder().url(wssUrl)
            .header("authorization", "Bearer ${expected.lease.token}").build()
        val listener = object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) = handleMessage(expected, webSocket, text)
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handleMessage(expected, webSocket, bytes.utf8())
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = scheduleReconnect(expected, webSocket)
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = scheduleReconnect(expected, webSocket)
        }
        expected.socket = socketFactory?.invoke(request, listener) ?: client.newWebSocket(request, listener)
    }

    private fun handleMessage(expected: Channel, socket: WebSocket, text: String) {
        if (!current(expected)) return
        synchronized(this) {
            if (channel !== expected || expected.socket !== socket) return
            expected.backoffSeconds = 1L
        }
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return // pong
        if (obj.optString("type") != "updated") return
        val version = BackupRevisionPolicy.parse(obj.opt("version")) ?: return
        if (version <= manager.lastAppliedVersion(expected.lease)) return
        queuePull(expected)
    }

    private fun queuePull(expected: Channel) {
        if (!current(expected)) return
        synchronized(this) {
            if (channel === expected) expected.requests.trySend(Unit)
        }
    }

    private fun scheduleReconnect(expected: Channel, failed: WebSocket) {
        if (!current(expected)) return
        synchronized(this) {
            if (channel !== expected || expected.socket !== failed) return
            expected.socket = null
            failed.cancel()
            expected.keepAlive?.cancel(); expected.keepAlive = null
            val waitMs = expected.backoffSeconds * 1_000
            expected.backoffSeconds = minOf(expected.backoffSeconds * 2, 30)
            expected.reconnect?.cancel()
            expected.reconnect = scope.launch {
                delay(waitMs)
                if (!isActive || !current(expected)) return@launch
                manager.admitRealtimeLease(expected.lease) {
                    synchronized(this@VortXSyncRealtime) {
                        if (channel === expected && expected.socket == null) {
                            connectLocked(expected); startKeepAliveLocked(expected)
                        }
                    }
                    true
                }
                queuePull(expected) // reconnect catches broadcasts missed while disconnected
            }
        }
    }

    private fun startKeepAliveLocked(expected: Channel) {
        expected.keepAlive?.cancel()
        expected.keepAlive = scope.launch {
            while (isActive) {
                delay(30_000)
                if (!isActive || !current(expected)) return@launch
                val socket = synchronized(this@VortXSyncRealtime) { expected.socket } ?: return@launch
                if (!socket.send("ping")) scheduleReconnect(expected, socket)
            }
        }
    }

    private fun startPollLocked(expected: Channel) {
        expected.poll?.cancel()
        expected.poll = scope.launch {
            while (isActive) {
                delay(ACTIVE_POLL_INTERVAL_MS)
                if (!isActive || !current(expected)) return@launch
                queuePull(expected)
            }
        }
    }

    internal companion object {
        const val ACTIVE_POLL_INTERVAL_MS = 3_000L
    }
}
