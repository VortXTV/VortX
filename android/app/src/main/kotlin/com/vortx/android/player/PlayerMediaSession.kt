package com.vortx.android.player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Looper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.platform.LocalContext
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.vortx.android.model.Playable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/// The system MediaSession for the player (issue #77): headset/Bluetooth transport buttons, the
/// Android TV now-playing surface, and assistant "pause"/"resume" all drive the session, which
/// drives the LIVE engine through the engine-agnostic [PlayerEngine] seam.
///
/// media3-session is already a declared dependency (see build.gradle.kts's media3 block), so this
/// uses the modern androidx.media3.session.MediaSession, NOT the legacy MediaSessionCompat. A media3
/// session wants a media3 [Player], and the libmpv engine is no such thing, so [EngineSessionPlayer]
/// adapts the seam via [SimpleBasePlayer], the artifact's own base class for exactly this "custom
/// player behind a session" shape: we declare a State snapshot + command set, it handles the Player
/// surface, threading checks, and listener diffing.
///
/// SCOPE, deliberately: the session lives exactly as long as the player composition (no
/// MediaSessionService, no media notification). VortX has no background playback (the lifecycle
/// observer pauses + drops decode at ON_STOP), so a service would advertise controls for playback
/// that cannot be running; in PiP the activity never stops, so the session stays live there, which
/// is the one "backgrounded but playing" state the app has.
///
/// D-PAD SAFETY (the TV contract): a MediaSession routes MEDIA transport keys (play/pause/ffwd/rew,
/// headset hook) only. D-pad arrows/center arrive through the ordinary window input pipeline into
/// the chrome's Compose focus system and [PlayerScreen]'s onKeyEvent, untouched by the session, so
/// TV navigation cannot be stolen by this file. Media keys the WINDOW consumes first (see
/// PlayerScreen's explicit media-key handling) never even reach the session; the session catches
/// the rest (screen-off remotes, headsets, assistant).
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
internal class EngineSessionPlayer(
    private val engine: PlayerEngine,
    playable: Playable,
    looper: Looper,
) : SimpleBasePlayer(looper) {

    /// The playback speed the chrome last applied (the engine does not republish it). Feeds the
    /// session's PlaybackParameters so controller position extrapolation stays honest at 1.25x.
    private var speed: Float = 1.0f

    /// One stable supplier instance: SimpleBasePlayer diffs State by equality, and a fresh lambda
    /// per snapshot would read as a position change on every invalidate, spamming controllers.
    private val positionSupplier = PositionSupplier { engine.state.value.positionMs.coerceAtLeast(0L) }

    /// The single session MediaItem: title/subtitle metadata for the lockscreen/now-playing row.
    /// No artwork: [Playable] carries no poster URL at this seam (the host resolves art at the
    /// catalog layer), and fetching one here would add a network path to every play for a thumbnail.
    private val mediaItemData: MediaItemData
    private var lastDurationMs: Long = Long.MIN_VALUE
    private var cachedItemData: MediaItemData

    init {
        val ref = playable.mediaRef
        val episodeTag = if (ref?.isSeries == true && ref.season != null && ref.episode != null) {
            "S${ref.season} E${ref.episode}"
        } else {
            null
        }
        val metadata = MediaMetadata.Builder()
            .setTitle(ref?.title?.takeIf { it.isNotBlank() } ?: playable.title)
            .setSubtitle(episodeTag)
            .build()
        mediaItemData = MediaItemData.Builder(SESSION_ITEM_UID)
            .setMediaItem(MediaItem.Builder().setMediaId(playable.url).setMediaMetadata(metadata).build())
            .build()
        cachedItemData = mediaItemData
    }

    override fun getState(): State {
        val s = engine.state.value
        val playbackState = when {
            s.hasError -> Player.STATE_IDLE
            s.hasEnded -> Player.STATE_ENDED
            s.isBuffering || s.durationMs <= 0L -> Player.STATE_BUFFERING
            else -> Player.STATE_READY
        }
        return State.Builder()
            .setAvailableCommands(AVAILABLE_COMMANDS)
            .setPlaybackState(playbackState)
            .setPlayWhenReady(!s.isPaused, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaylist(listOf(itemDataFor(s.durationMs)))
            .setCurrentMediaItemIndex(0)
            .setContentPositionMs(positionSupplier)
            .setPlaybackParameters(PlaybackParameters(speed))
            .setSeekBackIncrementMs(SESSION_SEEK_INCREMENT_MS)
            .setSeekForwardIncrementMs(SESSION_SEEK_INCREMENT_MS)
            .build()
    }

    override fun handleSetPlayWhenReady(playWhenReady: Boolean): ListenableFuture<*> {
        if (playWhenReady) engine.play() else engine.pause()
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        // TIME_UNSET is "the default position" (a seek-to-start class command); everything else is
        // an absolute target, which the engine clamps against its own duration.
        engine.seekTo(if (positionMs == C.TIME_UNSET) 0L else positionMs.coerceAtLeast(0L))
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> = Futures.immediateVoidFuture()

    /// Republish the current engine snapshot to session controllers. Called on the session looper
    /// (main) for every engine state emission; SimpleBasePlayer diffs, so a no-change emission
    /// (the common once-a-second position tick, served via [positionSupplier]) fires no events.
    fun publishFromEngine() {
        invalidateState()
    }

    /// The chrome applied a new playback speed on the engine; mirror it to controllers.
    fun setSpeedHint(newSpeed: Float) {
        if (speed == newSpeed) return
        speed = newSpeed
        invalidateState()
    }

    /// Rebuild the single-item playlist only when the reported duration changes (demux lands, or a
    /// junk file swap): MediaItemData carries the duration, and a cached instance keeps State diffs
    /// clean otherwise.
    private fun itemDataFor(durationMs: Long): MediaItemData {
        if (durationMs == lastDurationMs) return cachedItemData
        lastDurationMs = durationMs
        cachedItemData = mediaItemData
            .buildUpon()
            .setDurationUs(if (durationMs > 0L) durationMs * 1000L else C.TIME_UNSET)
            .build()
        return cachedItemData
    }

    private companion object {
        /// Stable uid for the session's single media item (SimpleBasePlayer keys items by uid).
        private const val SESSION_ITEM_UID = "vortx-player-item"

        /// 10s, matching the chrome's Replay10/Forward10 buttons and the double-tap gesture step.
        private const val SESSION_SEEK_INCREMENT_MS = 10_000L

        /// What controllers may drive: transport + seek + metadata reads. No playlist editing, no
        /// stop (Back is the app's exit gesture), no next/previous (the Up Next auto-advance is the
        /// host's flow, not a session command, and a bogus "next" button on the lockscreen that
        /// no-ops would read as broken).
        private val AVAILABLE_COMMANDS = Player.Commands.Builder()
            .addAll(
                Player.COMMAND_PLAY_PAUSE,
                Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_BACK,
                Player.COMMAND_SEEK_FORWARD,
                Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
                Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_METADATA,
                Player.COMMAND_GET_TIMELINE,
                Player.COMMAND_RELEASE,
            )
            .build()
    }
}

/// Own the MediaSession for the composed player: created when the engine lands, released when the
/// player (or that engine instance, on a mid-session ExoPlayer fallback) leaves. All construction
/// happens INSIDE the DisposableEffect, never in composition, so on an engine swap the old
/// session's release is ordered strictly before the new session's create (two live sessions in one
/// process must not overlap; the unique id is belt-and-suspenders for the same rule).
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
@Composable
internal fun PlayerMediaSessionEffect(
    engine: PlayerEngine,
    playable: Playable,
    speed: Float,
) {
    val context = LocalContext.current
    val currentSpeed by rememberUpdatedState(speed)
    DisposableEffect(engine, playable.url) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val player = EngineSessionPlayer(engine, playable, Looper.getMainLooper())
        // Fail-soft: a session build failure (an OEM MediaSessionManager quirk) must never take
        // playback down with it; the player simply runs session-less, as it did before this file.
        val session = runCatching {
            MediaSession.Builder(context, player)
                .setId("vortx-player-${SESSION_SEQUENCE.incrementAndGet()}")
                .apply { sessionActivityIntent(context)?.let { setSessionActivity(it) } }
                .build()
        }.getOrNull()
        // Every engine emission republishes through the adapter (diffed there); the speed hint
        // rides its own snapshot flow because the engine does not publish speed.
        scope.launch { engine.state.collect { player.publishFromEngine() } }
        scope.launch { snapshotFlow { currentSpeed }.collect { player.setSpeedHint(it) } }
        onDispose {
            scope.cancel()
            runCatching { session?.release() }
            runCatching { player.release() }
        }
    }
}

/// Tapping the system media controls should land back on whichever shell hosts the player
/// (MainActivity on touch, TvActivity on TV), resolved from the live context chain rather than
/// hardcoding one activity class.
private fun sessionActivityIntent(context: Context): PendingIntent? {
    val activity = context.findActivity() ?: return null
    return PendingIntent.getActivity(
        context,
        0,
        Intent(context, activity.javaClass),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

/// Process-unique session id counter: media3 throws on two live sessions with the same id, and the
/// engine-swap path can legitimately build a successor while the predecessor's release is in flight.
private val SESSION_SEQUENCE = AtomicInteger(0)
