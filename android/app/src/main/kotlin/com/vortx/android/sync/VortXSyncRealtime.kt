package com.vortx.android.sync

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Real-time pull channel for the VortX account: the Android port of the Apple client's WebSocket
 * SyncRoom leg (`VortXSyncManager.swift` `startRealtime` / `connectWebSocket` / `handle` /
 * `scheduleReconnect` / `startKeepAlive` / `startPoll`), over an OkHttp WebSocket
 * (HttpURLConnection, which the manager's HTTP helper uses, has no WebSocket support; OkHttp is
 * already on the runtime classpath as Coil3's documented default engine).
 *
 * Contract mirrored 1:1 from the Swift client so both platforms speak to the SAME worker SyncRoom:
 *  - CONNECT: `wss://` upgrade of the manager's API base + `/v1/sync/connect`, authenticated with the
 *    session bearer in the `authorization` header (the header the worker reads on upgrade).
 *  - KEEP-ALIVE: an application-level text "ping" every 30s so an idle room (the worker's Hibernation
 *    API) keeps the socket; the worker replies "pong", which [onMessage] ignores by design.
 *  - PUSHED UPDATE: a JSON text frame `{"type":"updated","version":<epoch-ms>}`. Only a version
 *    STRICTLY newer than the account's high-water mark triggers a pull, so this device's own push echo
 *    (and the keep-alive pong) never causes a redundant pull or a feedback loop with the manager's
 *    debounced push. [VortXSyncManager.syncDown] re-checks the same guard, so the pull is idempotent.
 *  - RECONNECT: on any failure/close, exponential backoff 1s doubling to a 30s cap, reset to 1s by any
 *    clean message. The while-active POLL (a guarded [VortXSyncManager.syncDown] every 10s) keeps
 *    changes flowing while the socket is down, exactly like the Apple fallback poll.
 *
 * LIFECYCLE: [start] on app-foreground and on sign-in; [stop] on app-background and inside
 *  [VortXSyncManager.signOut]. Both are idempotent and fail-soft: signed out or already running,
 *  [start] is a no-op; a missing/failed WebSocket never breaks the existing foreground pull path.
 *  The existing pull+debounced-push engine is UNCHANGED and remains the fallback; this only makes a
 *  peer's push land in seconds instead of at the next foreground.
 *
 * The token is read per-connect from the manager's session (never stored here, never logged). All
 * state transitions are `synchronized` on this object: [start]/[stop] arrive on the main thread while
 * the OkHttp listener calls back on its own reader thread.
 */
internal class VortXSyncRealtime(
    private val manager: VortXSyncManager,
    private val scope: CoroutineScope,
    private val wssUrl: String,
) {

    /** Built on first [start] (never at manager construction): a websocket-only client, no interceptors. */
    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
            // No read timeout on a long-lived socket: silence between pushes is normal; liveness comes
            // from the app-level ping (a send failure surfaces in onFailure and triggers the reconnect).
            .readTimeout(0, TimeUnit.SECONDS)
            .build()
    }

    /** True between [start] and [stop] (the Apple `realtimeActive`). */
    private var active = false

    /** The live socket; compared by identity in the listener so a stale socket's late callback is ignored. */
    private var ws: WebSocket? = null

    private var keepAlive: Job? = null
    private var reconnect: Job? = null
    private var poll: Job? = null

    /** Reconnect delay in seconds, doubled per failure (capped), reset by any clean message. */
    private var backoffSeconds = 1L

    /** Open the channel: socket + keep-alive + fallback poll + one immediate catch-up pull. */
    fun start() {
        synchronized(this) {
            if (active || !manager.isSignedIn) return
            active = true
            backoffSeconds = 1L
            connect()
            startKeepAlive()
            startPoll()
        }
        // Catch up immediately on the way in (the Apple scene-active pull): a change made while this
        // device was backgrounded applies now rather than waiting for the next push broadcast. syncDown
        // is version-guarded and defers to a queued local push, so this can never clobber local state.
        scope.launch { manager.syncDown() }
    }

    /** Close the channel: tear down the socket, reconnect, keep-alive, and the poll. Safe to repeat. */
    fun stop() {
        synchronized(this) {
            active = false
            reconnect?.cancel(); reconnect = null
            keepAlive?.cancel(); keepAlive = null
            poll?.cancel(); poll = null
            ws?.close(CLOSE_GOING_AWAY, null)
            ws = null
        }
    }

    private fun connect() {
        val token = manager.currentSession()?.token ?: return
        val request = Request.Builder()
            .url(wssUrl)
            // Lowercase to match the worker's read and the manager's HTTP helper; the value is the
            // session bearer and is never logged (OkHttp is not given any logging interceptor).
            .header("authorization", "Bearer $token")
            .build()
        ws = client.newWebSocket(request, listener)
    }

    private val listener = object : WebSocketListener() {
        override fun onMessage(webSocket: WebSocket, text: String) {
            handleMessage(webSocket, text)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            handleMessage(webSocket, bytes.utf8())
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            scheduleReconnect(webSocket)
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            // The server is closing the socket (e.g. a room eviction). Treat like a drop: the backoff
            // reconnect re-opens it if we are still active; stop()'s own close is filtered by identity.
            scheduleReconnect(webSocket)
        }
    }

    private fun handleMessage(socket: WebSocket, text: String) {
        synchronized(this) {
            if (ws !== socket) return                     // a stale socket's late frame
            backoffSeconds = 1L                           // any clean message means the link is healthy
        }
        val obj = runCatching { JSONObject(text) }.getOrNull() ?: return   // "pong" and friends
        if (obj.optString("type") != "updated") return
        // Version is a 64-bit epoch-ms value: read as LONG (the same rule as the manager's pull path).
        // Only pull when the broadcast is genuinely newer than what we hold -- the up-front version
        // guard that keeps our own push echo from triggering a pull loop.
        if (obj.optLong("version", 0L) <= manager.lastAppliedVersion()) return
        scope.launch { manager.syncDown() }               // re-checks the guard: idempotent
    }

    private fun scheduleReconnect(failed: WebSocket) {
        synchronized(this) {
            if (ws !== failed) return                     // stop()/a newer connect already superseded it
            ws?.cancel()
            ws = null
            keepAlive?.cancel(); keepAlive = null
            if (!active || !manager.isSignedIn) return
            val delaySeconds = backoffSeconds
            backoffSeconds = minOf(backoffSeconds * 2, MAX_BACKOFF_S)
            reconnect?.cancel()
            reconnect = scope.launch {
                delay(delaySeconds * 1_000)
                if (!isActive) return@launch
                synchronized(this@VortXSyncRealtime) {
                    if (active && manager.isSignedIn && ws == null) {
                        connect()
                        startKeepAlive()
                    }
                }
            }
        }
    }

    /** Periodic app-level "ping" so an idle room keeps our socket; a failed send surfaces in onFailure. */
    private fun startKeepAlive() {
        keepAlive?.cancel()
        keepAlive = scope.launch {
            while (isActive) {
                delay(KEEP_ALIVE_MS)
                if (!isActive) return@launch
                val socket = synchronized(this@VortXSyncRealtime) { ws } ?: return@launch
                socket.send("ping")
            }
        }
    }

    /**
     * Lightweight fallback: while active, pull every ~10s so changes propagate near-real-time even if
     * the WebSocket is unavailable. Cheap (the version guard skips no-op pulls), cancelled on [stop].
     */
    private fun startPoll() {
        poll?.cancel()
        poll = scope.launch {
            while (isActive) {
                delay(POLL_INTERVAL_MS)
                if (!isActive) return@launch
                manager.syncDown()   // guarded: only strictly-newer versions apply; defers to a queued push
            }
        }
    }

    private companion object {
        const val CONNECT_TIMEOUT_S = 20L
        /** Apple `wsMaxBackoff` = 30s. */
        const val MAX_BACKOFF_S = 30L
        /** Apple `keepAliveNanos` = 30s. */
        const val KEEP_ALIVE_MS = 30_000L
        /** Apple `pollIntervalNanos` = 10s. */
        const val POLL_INTERVAL_MS = 10_000L
        /** RFC 6455 "going away", the analogue of the Apple close code on stop. */
        const val CLOSE_GOING_AWAY = 1001
    }
}
