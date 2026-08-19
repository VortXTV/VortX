package com.vortx.android.cast

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.CastState
import com.google.android.gms.cast.framework.CastStateListener
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.vortx.android.model.Playable
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/// Runtime owner of the Google Cast session for the player. Wraps the framework's `CastContext` /
/// `SessionManager` / `RemoteMediaClient` behind a single [CastPlaybackState] `StateFlow` the Compose layer
/// collects, so the player never touches Cast SDK types directly. Conceptually this is the Cast counterpart
/// of the Apple AirPlay handoff: it loads the current stream (URL + subtitles + start position) onto the
/// receiver, exposes transport control, and remembers the last receiver position so local playback can
/// resume on disconnect.
///
/// Fail-soft by construction: if the framework cannot initialize (no Google Play services, or the receiver
/// options provider is missing) `getSharedInstance` throws and [isEnabled] is false -- every method no-ops
/// and the button never shows, so a device without Cast degrades cleanly instead of crashing. All Cast
/// callbacks arrive on the main thread, which is also where the composition creates and drives this object,
/// so the plain (non-synchronized) fields are safe.
class CastManager(appContext: Context) {

    private val castContext: CastContext? =
        @Suppress("DEPRECATION")
        runCatching { CastContext.getSharedInstance(appContext) }.getOrNull()

    /// True only when the Cast framework initialized. The host gates the whole cast lane (button + overlay)
    /// on this, so a build/device without Play services shows no cast affordances at all.
    val isEnabled: Boolean get() = castContext != null

    private val _state = MutableStateFlow(CastPlaybackState())
    val state: StateFlow<CastPlaybackState> = _state.asStateFlow()

    /// The last receiver playhead we observed, in milliseconds. Captured continuously while connected and
    /// read by the host on disconnect to resume local playback where the receiver left off (the
    /// "resume local playback on disconnect" behavior). Survives the session teardown that clears the
    /// RemoteMediaClient.
    var lastKnownPositionMs: Long = 0L
        private set

    // What to cast, set by the host whenever the current stream changes. The position provider is read at
    // load time so the receiver starts exactly where local playback is (not a stale snapshot).
    private var nowPlaying: Playable? = null
    private var positionProvider: () -> Long = { 0L }

    private var currentSession: CastSession? = null
    private var remoteMediaClient: RemoteMediaClient? = null

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarted(session: CastSession, sessionId: String) = bind(session, freshLoad = true)
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            // Rebind only if we lost the client (app cold-resumed into a live session). A resume after a
            // transient suspend kept the client attached, so just re-adopt the session and flip back to
            // CONNECTED without re-registering callbacks (which would double them up).
            val rmc = remoteMediaClient
            if (rmc == null) {
                bind(session, freshLoad = false)
            } else {
                currentSession = session
                refreshPlaybackState()
            }
        }
        override fun onSessionStarting(session: CastSession) = markConnecting()
        override fun onSessionResuming(session: CastSession, sessionId: String) = markConnecting()
        override fun onSessionStartFailed(session: CastSession, error: Int) = unbind()
        override fun onSessionResumeFailed(session: CastSession, error: Int) = unbind()
        override fun onSessionEnding(session: CastSession) = captureLastPosition()
        override fun onSessionEnded(session: CastSession, error: Int) = unbind()
        // A transient LAN blip SUSPENDS then RESUMES the same session: keep the connection (do NOT tear the
        // client down) and show a lighter connecting/buffering state; only onSessionEnded fully unbinds.
        override fun onSessionSuspended(session: CastSession, reason: Int) = markSuspended()
    }

    private val castStateListener = CastStateListener { newState -> applyAvailability(newState) }

    private val progressListener = RemoteMediaClient.ProgressListener { progressMs, durationMs ->
        if (progressMs >= 0L) lastKnownPositionMs = progressMs
        _state.value = _state.value.copy(
            positionMs = progressMs.coerceAtLeast(0L),
            durationMs = if (durationMs > 0L) durationMs else _state.value.durationMs,
        )
    }

    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = refreshPlaybackState()
        override fun onMetadataUpdated() = refreshPlaybackState()
    }

    /// Begin observing the framework. Called from [rememberCastManager]'s `DisposableEffect` when the player
    /// enters composition. Syncs any already-live session (e.g. the user was already casting from a browse
    /// screen) so re-entering the player picks up the running cast.
    fun attach() {
        val context = castContext ?: return
        context.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        context.addCastStateListener(castStateListener)
        applyAvailability(context.castState)
        context.sessionManager.currentCastSession?.let { bind(it, freshLoad = false) }
    }

    /// Stop observing the framework and detach the RemoteMediaClient callbacks. Does NOT end the cast
    /// session -- leaving the player must not stop a cast in progress (the user may keep watching on the TV).
    fun detach() {
        val context = castContext ?: return
        context.sessionManager.removeSessionManagerListener(sessionListener, CastSession::class.java)
        context.removeCastStateListener(castStateListener)
        remoteMediaClient?.let {
            it.removeProgressListener(progressListener)
            it.unregisterCallback(mediaCallback)
        }
        remoteMediaClient = null
        currentSession = null
    }

    /// Tell the manager what the player is currently showing. Called by the host on the initial mount and on
    /// every in-player source / episode switch. If a receiver is already connected and the new stream is
    /// castable, it is loaded immediately so an episode switch keeps casting; otherwise it is remembered and
    /// loaded when a session starts.
    fun setNowPlaying(playable: Playable?, positionProvider: () -> Long) {
        this.nowPlaying = playable
        this.positionProvider = positionProvider
        // SYNC vs SWITCH. Adopting the current selection must NEVER reload: re-entering the player while
        // already casting this exact stream, or re-attaching to a session whose media we do not yet know,
        // would otherwise snap the receiver back to a STALE local (paused) position and discard real cast
        // progress. Reload ONLY on a genuine media change -- a DIFFERENT url is already loaded on a live
        // session (an in-player episode/source switch, or opening a new title while connected). The
        // receiver's own loaded contentId (set to the stream url by [CastMediaRequest]) is the identity.
        if (currentSession == null || playable == null || !CastEligibility.isCastable(playable)) return
        val loadedUrl = remoteMediaClient?.mediaInfo?.contentId
        if (loadedUrl != null && loadedUrl != playable.url) loadCurrent()
    }

    fun play() { remoteMediaClient?.play() }
    fun pause() { remoteMediaClient?.pause() }

    fun togglePause() {
        val rmc = remoteMediaClient ?: return
        if (rmc.isPaused) rmc.play() else rmc.pause()
    }

    fun seekTo(positionMs: Long) {
        remoteMediaClient?.seek(
            MediaSeekOptions.Builder().setPosition(positionMs.coerceAtLeast(0L)).build(),
        )
    }

    fun seekBy(deltaMs: Long) {
        val s = _state.value
        val upper = if (s.durationMs > 0L) s.durationMs else Long.MAX_VALUE
        seekTo((s.positionMs + deltaMs).coerceIn(0L, upper))
    }

    /// End the cast session from the app (the "Stop casting" control). The framework fires onSessionEnding /
    /// onSessionEnded, which captures the last position and flips state back to disconnected; the host's
    /// disconnect effect then resumes local playback there.
    fun stopCasting() {
        castContext?.sessionManager?.endCurrentSession(true)
    }

    private fun bind(session: CastSession, freshLoad: Boolean) {
        currentSession = session
        val rmc = session.remoteMediaClient
        remoteMediaClient = rmc
        rmc?.registerCallback(mediaCallback)
        rmc?.addProgressListener(progressListener, PROGRESS_PERIOD_MS)
        refreshPlaybackState()
        if (freshLoad) {
            val playable = nowPlaying
            if (playable != null && CastEligibility.isCastable(playable)) loadCurrent()
        }
    }

    private fun loadCurrent() {
        val rmc = remoteMediaClient ?: return
        val playable = nowPlaying ?: return
        rmc.load(CastMediaRequest.build(playable, positionProvider()))
    }

    private fun captureLastPosition() {
        remoteMediaClient?.approximateStreamPosition?.takeIf { it > 0L }?.let { lastKnownPositionMs = it }
    }

    private fun unbind() {
        captureLastPosition()
        remoteMediaClient?.let {
            it.removeProgressListener(progressListener)
            it.unregisterCallback(mediaCallback)
        }
        remoteMediaClient = null
        currentSession = null
        _state.value = _state.value.copy(
            deviceName = null,
            isConnected = false,
            isPlaying = false,
            isPaused = false,
            isBuffering = false,
        )
        castContext?.let { applyAvailability(it.castState) }
    }

    private fun markConnecting() {
        _state.value = _state.value.copy(availability = CastAvailability.CONNECTING)
    }

    // A transient suspend keeps the session connected: capture the last position and show a lighter
    // connecting/buffering state, but DO NOT drop the client -- onSessionResumed re-adopts it, and only
    // onSessionEnded fully unbinds. isConnected stays true so local playback does not prematurely resume.
    private fun markSuspended() {
        captureLastPosition()
        _state.value = _state.value.copy(
            availability = CastAvailability.CONNECTING,
            isBuffering = true,
        )
    }

    private fun refreshPlaybackState() {
        val rmc = remoteMediaClient
        val connected = currentSession != null
        val position = rmc?.approximateStreamPosition ?: 0L
        val duration = rmc?.streamDuration ?: 0L
        if (position > 0L) lastKnownPositionMs = position
        _state.value = _state.value.copy(
            availability = if (connected) CastAvailability.CONNECTED else _state.value.availability,
            deviceName = currentSession?.castDevice?.friendlyName,
            isConnected = connected,
            isPlaying = rmc?.isPlaying == true,
            isPaused = rmc?.isPaused == true,
            isBuffering = rmc?.isBuffering == true,
            positionMs = if (position > 0L) position else _state.value.positionMs,
            durationMs = if (duration > 0L) duration else _state.value.durationMs,
        )
    }

    private fun applyAvailability(castState: Int) {
        val availability = when (castState) {
            CastState.NO_DEVICES_AVAILABLE -> CastAvailability.NO_DEVICES
            CastState.NOT_CONNECTED -> CastAvailability.AVAILABLE
            CastState.CONNECTING -> CastAvailability.CONNECTING
            CastState.CONNECTED -> CastAvailability.CONNECTED
            else -> CastAvailability.UNAVAILABLE
        }
        _state.value = _state.value.copy(availability = availability)
    }

    private companion object {
        /// How often the receiver reports its playhead. 1s matches the local player's progress cadence and
        /// keeps [lastKnownPositionMs] fresh enough for an accurate resume-on-disconnect.
        const val PROGRESS_PERIOD_MS = 1_000L
    }
}

/// Create and lifecycle-bind a [CastManager] for the current composition. Attaches on entry and detaches on
/// exit (which never ends an in-flight cast). Returns a disabled manager (isEnabled == false) on any device
/// without the Cast framework, so callers can wire it unconditionally.
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
