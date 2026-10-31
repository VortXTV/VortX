package com.vortx.android.cast

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.CastState
import com.google.android.gms.cast.framework.CastStateListener
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.vortx.android.model.Playable
import com.vortx.android.player.canReportPlayerProgress
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Main-thread SDK adapter. Session ordering and all media/history proof live in the tested coordinator. */
class CastManager(appContext: Context) {
    private val castContext: CastContext? =
        @Suppress("DEPRECATION")
        runCatching { CastContext.getSharedInstance(appContext) }.getOrNull()
    val isEnabled: Boolean get() = castContext != null
    private val _state = MutableStateFlow(CastPlaybackState())
    val state: StateFlow<CastPlaybackState> = _state.asStateFlow()
    private var timelineListener: (CastTimelineUpdate) -> Unit = {}
    private val coordinator = CastSessionCoordinator(validProgress = { pos, dur ->
        nowPlaying?.let { canReportPlayerProgress(it, pos, dur) } == true
    }) { timelineListener(it) }
    private var selectionOwner: String? = null
    private var nowPlaying: Playable? = null
    private var positionProvider: () -> Long = { 0L }
    private var selectionIsCurrent: () -> Boolean = { false }
    private var observed: CastSessionCoordinator.Binding? = null
    private var callback: RemoteMediaClient.Callback? = null
    private var attached = false
    private var preservingExit = false
    private var statusRequestInFlight = false
    private var lastStatusRequestMs = Long.MIN_VALUE
    private val handler = Handler(Looper.getMainLooper())
    private val clock = object : Runnable {
        override fun run() {
            if (!attached) return
            handle(coordinator.tick(selectionIsCurrent(), now()))
            syncCallback()
            publish()
            requestStatus()
            handler.postDelayed(this, 1_000L)
        }
    }
    private val sessions = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {
            val route = session.castDevice?.deviceId ?: return
            coordinator.starting(session, route, now())
        }
        override fun onSessionStarted(session: CastSession, sessionId: String) {
            val client = session.remoteMediaClient ?: return
            if (session !== castContext?.sessionManager?.currentCastSession) return
            val route = session.castDevice?.deviceId ?: return
            val ticket = coordinator.started(session, client, route, now(), castContext?.sessionManager?.currentCastSession)
            syncCallback()
            if (ticket != null) load(ticket)
            publish()
        }
        override fun onSessionResuming(session: CastSession, sessionId: String) {
            val client = session.remoteMediaClient
            val route = session.castDevice?.deviceId
            if (route == null) {
                // A missing SDK device grants no replacement identity. Bound suspension can still
                // begin for this exact already-owned session without adopting a different route.
                coordinator.binding?.takeIf { it.session === session }?.let {
                    coordinator.suspended(it.session, it.client, now())
                }
                syncCallback(); publish()
                return
            }
            if (client == null) {
                // CAF may clear the SDK client before the lifecycle callback. The retained owned
                // binding still starts the original suspension bound; it grants no replacement proof.
                coordinator.binding?.takeIf { it.route == route }?.let {
                    coordinator.suspended(it.session, it.client, now())
                }
                syncCallback(); publish()
                return
            }
            coordinator.resuming(session, client, route, now())
            syncCallback(); publish(); requestStatus()
        }
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            val client = session.remoteMediaClient ?: return
            if (session !== castContext?.sessionManager?.currentCastSession) return
            val route = session.castDevice?.deviceId ?: return
            val ticket = coordinator.resumed(session, client, route, now(), castContext?.sessionManager?.currentCastSession)
            syncCallback()
            if (ticket != null) load(ticket)
            publish(); requestStatus()
        }
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            val client = session.remoteMediaClient ?: coordinator.binding?.takeIf { it.session === session }?.client ?: return
            coordinator.suspended(session, client, now())
            syncCallback(); publish()
        }
        override fun onSessionStartFailed(session: CastSession, error: Int) = ended(session)
        override fun onSessionResumeFailed(session: CastSession, error: Int) = ended(session)
        override fun onSessionEnding(session: CastSession) = Unit
        override fun onSessionEnded(session: CastSession, error: Int) = ended(session)
    }
    private val availability = CastStateListener { applyAvailability(it) }
    private fun now() = SystemClock.elapsedRealtime()
    private fun ended(session: CastSession) {
        coordinator.ended(session)
        syncCallback(); publish()
        castContext?.let { applyAvailability(it.castState) }
    }
    fun attach() {
        val context = castContext ?: return
        if (attached) return
        attached = true
        context.sessionManager.addSessionManagerListener(sessions, CastSession::class.java)
        context.addCastStateListener(availability)
        applyAvailability(context.castState)
        context.sessionManager.currentCastSession?.let { session ->
            val route = session.castDevice?.deviceId ?: return@let
            session.remoteMediaClient?.let { coordinator.observe(session, it, route) }
        }
        syncCallback()
        handler.post(clock)
    }
    fun detach() {
        attached = false
        handler.removeCallbacks(clock)
        castContext?.sessionManager?.removeSessionManagerListener(sessions, CastSession::class.java)
        castContext?.removeCastStateListener(availability)
        coordinator.detach()
        removeCallback()
        publish()
    }
    internal fun setNowPlaying(owner: String, playable: Playable?, positionProvider: () -> Long,
        isCurrent: () -> Boolean, timeline: (CastConfirmedProgress?, Boolean, Long?) -> Unit) {
        val next = owner.takeIf { playable != null }
        handle(coordinator.select(next))
        if (selectionOwner != next) preservingExit = false
        selectionOwner = next
        nowPlaying = playable
        this.positionProvider = positionProvider
        selectionIsCurrent = isCurrent
        timelineListener = { timeline(it.point, it.remoteActive, it.resumePositionMs) }
        syncCallback(); publish()
    }
    /** The device ID comes from the selected route's CastDevice extras, not from ambient connectivity. */
    fun requestCast(deviceId: String, alreadySelected: Boolean) {
        val owner = selectionOwner ?: return
        val playable = nowPlaying ?: return
        if (preservingExit || !selectionIsCurrent() || !CastEligibility.isCastable(playable)) return
        val session = castContext?.sessionManager?.currentCastSession
        if (alreadySelected && session?.castDevice?.deviceId == deviceId && ownsCurrentMedia()) return
        if (!coordinator.chooseRoute(owner, deviceId, now())) return
        if (alreadySelected && session != null && session.castDevice?.deviceId == deviceId) {
            val client = session.remoteMediaClient ?: return
            coordinator.starting(session, deviceId, now())
            val ticket = coordinator.started(session, client, deviceId, now(), session)
            syncCallback()
            if (ticket != null) load(ticket)
        }
        publish()
    }
    /** Runs before the host exit flag: authorized Back preserves; an already-revoked owner stops exactly. */
    fun leavePlayer(owner: String) {
        if (selectionOwner != owner) return
        val admitted = selectionIsCurrent()
        preservingExit = admitted
        handle(coordinator.prepareExit(owner, admitted))
        if (admitted) removeCallback() else syncCallback()
        publish()
    }
    fun takeResumePosition(owner: String): Long? = coordinator.takeResume(owner)?.positionMs
    fun confirmedProgress(owner: String): CastConfirmedProgress? = coordinator.confirmed(owner)
    fun play() { if (ownsCurrentMedia()) client()?.play() }
    fun pause() { if (ownsCurrentMedia()) client()?.pause() }
    fun togglePause() {
        if (!ownsCurrentMedia()) return
        client()?.let { if (coordinator.isPaused) it.play() else it.pause() }
    }
    fun seekTo(positionMs: Long) {
        if (!ownsCurrentMedia()) return
        val target = coordinator.seek(positionMs, now()) ?: return
        client()?.seek(MediaSeekOptions.Builder().setPosition(target).build())
        publish(); requestStatus()
    }
    fun seekBy(deltaMs: Long) {
        val point = coordinator.point ?: return
        seekTo((point.positionMs + deltaMs).coerceIn(0L, point.durationMs))
    }
    fun stopCasting() {
        val owned = ownsCurrentMedia()
        handle(coordinator.retire(stopReceiver = !owned))
        publish()
        if (owned) castContext?.sessionManager?.endCurrentSession(true)
    }
    private fun client(): RemoteMediaClient? = coordinator.binding?.client as? RemoteMediaClient
    private fun ownsCurrentMedia(): Boolean {
        val binding = coordinator.binding ?: return false
        val session = binding.session as? CastSession ?: return false
        return !preservingExit && selectionIsCurrent() && coordinator.canControl &&
            session === castContext?.sessionManager?.currentCastSession && session.remoteMediaClient === binding.client &&
            client()?.mediaInfo?.customData?.optString(CastMediaRequest.LOAD_ID_KEY) == coordinator.loadId
    }
    private fun load(ticket: CastSessionCoordinator.LoadTicket) {
        val playable = nowPlaying ?: return
        val client = ticket.binding.client as? RemoteMediaClient ?: return
        if (!selectionIsCurrent() || !CastEligibility.isCastable(playable)) return
        val start = positionProvider().coerceIn(0L, CastSessionCoordinator.MAX_POSITION_MS)
        val id = UUID.randomUUID().toString()
        val request = CastMediaRequest.build(playable, start, id)
        if (!selectionIsCurrent() || !CastEligibility.isCastable(playable) || !coordinator.begin(ticket, id, now())) return
        runCatching { client.load(request) }.onSuccess { pending ->
            pending.setResultCallback { result ->
                // Reconnect keeps the media UUID but advances its binding. An old LOAD result
                // must never retire or stop that resumed generation.
                if (coordinator.loadId == id && ticket.binding.same(coordinator.binding) && !result.status.isSuccess) {
                    handle(coordinator.retire(stopReceiver = true)); publish()
                }
            }
        }.onFailure { if (coordinator.loadId == id && ticket.binding.same(coordinator.binding)) { coordinator.retire(false); publish() } }
        requestStatus()
    }
    private fun handle(stop: CastSessionCoordinator.Stop?) {
        if (stop == null) return
        val session = stop.binding.session as? CastSession ?: return
        val client = stop.binding.client as? RemoteMediaClient ?: return
        if (session === castContext?.sessionManager?.currentCastSession && session.remoteMediaClient === client &&
            client.mediaInfo?.customData?.optString(CastMediaRequest.LOAD_ID_KEY) == stop.loadId) client.stop()
    }
    private fun syncCallback() {
        if (preservingExit) { removeCallback(); return }
        val current = coordinator.binding
        if (current?.epoch == observed?.epoch && current?.client === observed?.client && current?.session === observed?.session) return
        removeCallback()
        val binding = current ?: return
        val client = binding.client as? RemoteMediaClient ?: return
        observed = binding
        val listener = object : RemoteMediaClient.Callback() {
            override fun onStatusUpdated() {
                if (preservingExit || observed !== binding) return
                // CAF may replace its current session/client before lifecycle callbacks catch up.
                // An old SDK callback must not publish progress for that retired connection.
                val session = binding.session as? CastSession ?: return
                if (session !== castContext?.sessionManager?.currentCastSession || session.remoteMediaClient !== client) return
                handle(coordinator.tick(selectionIsCurrent(), now()))
                val status = client.mediaStatus ?: return
                coordinator.freshStatus(binding, CastSessionCoordinator.Status(
                    receipt = status.mediaInfo?.customData?.optString(CastMediaRequest.LOAD_ID_KEY),
                    positionMs = status.streamPosition,
                    durationMs = status.mediaInfo?.streamDuration ?: 0L,
                    playing = status.playerState == MediaStatus.PLAYER_STATE_PLAYING,
                    paused = status.playerState == MediaStatus.PLAYER_STATE_PAUSED,
                    buffering = status.playerState == MediaStatus.PLAYER_STATE_BUFFERING,
                ), now())
                publish()
            }
        }
        callback = listener
        client.registerCallback(listener)
        // Registering/binding and request completion never call freshStatus. Only a received status does.
    }
    private fun removeCallback() {
        val client = observed?.client as? RemoteMediaClient
        callback?.let { client?.unregisterCallback(it) }
        callback = null; observed = null
        statusRequestInFlight = false
        lastStatusRequestMs = Long.MIN_VALUE
    }
    private fun requestStatus() {
        if (preservingExit || coordinator.loadId == null || statusRequestInFlight) return
        val binding = observed ?: return
        val client = binding.client as? RemoteMediaClient ?: return
        val time = now()
        if (lastStatusRequestMs != Long.MIN_VALUE && time - lastStatusRequestMs < 1_000L) return
        lastStatusRequestMs = time
        statusRequestInFlight = true
        runCatching { client.requestStatus() }.onSuccess { pending ->
            pending.setResultCallback { if (observed === binding) statusRequestInFlight = false }
        }.onFailure { if (observed === binding) statusRequestInFlight = false }
    }
    private fun publish() {
        val point = coordinator.point
        _state.value = _state.value.copy(owner = coordinator.currentOwner, isConnected = coordinator.isOwned,
            deviceName = (coordinator.binding?.session as? CastSession)?.castDevice?.friendlyName,
            isPlaying = coordinator.isPlaying, isPaused = coordinator.isPaused, isBuffering = coordinator.isBuffering,
            positionMs = point?.positionMs ?: 0L, durationMs = point?.durationMs ?: 0L)
    }
    private fun applyAvailability(state: Int) {
        val value = when (state) {
            CastState.NO_DEVICES_AVAILABLE -> CastAvailability.NO_DEVICES
            CastState.NOT_CONNECTED -> CastAvailability.AVAILABLE
            CastState.CONNECTING -> CastAvailability.CONNECTING
            CastState.CONNECTED -> CastAvailability.CONNECTED
            else -> CastAvailability.UNAVAILABLE
        }
        _state.value = _state.value.copy(availability = value)
    }
}

@Composable
fun rememberCastManager(): CastManager {
    val context = LocalContext.current
    val manager = remember(context) { CastManager(context.applicationContext) }
    DisposableEffect(manager) {
        manager.attach()
        onDispose { manager.detach() }
    }
    return manager
}
