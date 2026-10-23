package com.vortx.android.sync

import com.vortx.android.diagnostics.DiagnosticsLog
import kotlinx.coroutines.CancellationException
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

/** Account-captured SyncRoom channel, foreground-only fallback poll, and coalesced catch-up pulls.
 * Socket identity AND the exact authenticated session generation fence every callback/task.
 * No bearer is logged or stored independently of that immutable session lease. */
internal class VortXSyncRealtime(
    private val manager: VortXSyncManager,
    private val scope: CoroutineScope,
    private val wssUrl: String,
    /** Monotonic milliseconds for the fallback poll's spacing; tests pass virtual time. */
    private val clockMs: () -> Long = { System.nanoTime() / 1_000_000 },
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
        var heardAtMs: Long? = null // last frame from this socket (the worker answers each ping)
        var lastPollMs: Long? = null
    }
    private var channel: Channel? = null

    fun start() {
        // Never acquire the auth coordinator while holding the channel monitor: sign-out closes
        // realtime under that coordinator, so the inverse edge would deadlock.
        val lease = manager.captureRealtimeLease() ?: return
        val prior = synchronized(this) { channel }
        if (prior != null && current(prior)) return
        var next: Channel? = null
        try {
            // Final outbound admission follows auth → channel, the same order as sign-out.
            manager.admitRealtimeLease(lease) {
                synchronized(this) {
                    stopLocked()
                    val opening = Channel(lease)
                    next = opening
                    channel = opening
                    if (connectLocked(opening)) startKeepAliveLocked(opening)
                    startPollLocked(opening)
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
        } catch (cancel: CancellationException) {
            synchronized(this) { if (next != null && channel === next) stopLocked() }
            throw cancel
        } catch (_: Exception) {
            synchronized(this) { if (next != null && channel === next) stopLocked() }
            // Closed categories only: exception messages can contain an endpoint or bearer.
            DiagnosticsLog.log("sync", "realtime result=unavailable stage=start reason=setup_failed")
        }
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

    private fun connectLocked(expected: Channel): Boolean {
        return try {
            val request = Request.Builder().url(wssUrl)
                .header("authorization", "Bearer " + expected.lease.token).build()
            val listener = object : WebSocketListener() {
                override fun onMessage(webSocket: WebSocket, text: String) = handleMessage(expected, webSocket, text)
                override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handleMessage(expected, webSocket, bytes.utf8())
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = scheduleReconnect(expected, webSocket)
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) = scheduleReconnect(expected, webSocket)
            }
            expected.socket = socketFactory?.invoke(request, listener) ?: client.newWebSocket(request, listener)
            true
        } catch (cancel: CancellationException) { throw cancel }
        catch (_: Exception) {
            expected.socket = null
            DiagnosticsLog.log("sync", "realtime result=degraded stage=connect reason=socket_start_failed")
            scheduleReconnectLocked(expected)
            false // Startup still installs the captured pull worker and fallback poll.
        }
    }

    private fun handleMessage(expected: Channel, socket: WebSocket, text: String) {
        if (!current(expected)) return
        synchronized(this) {
            if (channel !== expected || expected.socket !== socket) return
            expected.backoffSeconds = 1L
            expected.heardAtMs = clockMs()
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
            scheduleReconnectLocked(expected)
        }
    }

    /** Caller holds the channel monitor. The same backoff covers synchronous and callback failures. */
    private fun scheduleReconnectLocked(expected: Channel) {
        expected.heardAtMs = null
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
                        if (connectLocked(expected)) startKeepAliveLocked(expected)
                    }
                }
                true
            }
            queuePull(expected) // reconnect catches broadcasts missed while disconnected
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
                val now = clockMs()
                val due = synchronized(this@VortXSyncRealtime) {
                    val heard = if (expected.socket != null) expected.heardAtMs else null
                    shouldPoll(now, expected.lastPollMs, heard).also { if (it) expected.lastPollMs = now }
                }
                if (due) queuePull(expected)
            }
        }
    }

    internal companion object {
        const val ACTIVE_POLL_INTERVAL_MS = 3_000L
        const val LIVE_SOCKET_POLL_INTERVAL_MS = 5 * 60_000L
        const val SOCKET_SILENCE_LIMIT_MS = 75_000L

        /** The poll backs up the socket, which announces another device's change as it lands. While the socket
         * answers, a pull is due every five minutes (owner, 2026-10-17), since each pull of a newer revision
         * downloads and merges the whole account and this device's own uploads made the next tick do that
         * again. Silent past two missed keep-alive replies, every tick pulls. Same rule as Apple's
         * NativeForegroundSyncPolicy.ActivePoll. */
        fun shouldPoll(nowMs: Long, lastPollMs: Long?, socketHeardAtMs: Long?): Boolean {
            val heard = socketHeardAtMs ?: return true
            val silence = nowMs - heard
            if (silence < 0 || silence >= SOCKET_SILENCE_LIMIT_MS) return true
            val last = lastPollMs ?: return true
            val since = nowMs - last
            return since < 0 || since >= LIVE_SOCKET_POLL_INTERVAL_MS
        }
    }
}
