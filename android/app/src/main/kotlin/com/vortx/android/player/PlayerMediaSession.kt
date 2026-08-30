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
import coil3.request.allowHardware
import coil3.toBitmap
import com.vortx.android.model.Playable
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
    private val playable: Playable,
    private val setUserPlaying: (Boolean) -> Unit,
    looper: Looper,
) : SimpleBasePlayer(looper) {

    /// The playback speed the chrome last applied (the engine does not republish it). Feeds the
    /// session's PlaybackParameters so controller position extrapolation stays honest at 1.25x.
    private var speed: Float = 1.0f

    /// One stable supplier instance: SimpleBasePlayer diffs State by equality, and a fresh lambda
    /// per snapshot would read as a position change on every invalidate, spamming controllers.
    private val positionSupplier = PositionSupplier { engine.state.value.positionMs.coerceAtLeast(0L) }

    /// The Now-Playing identity + display metadata derived once from [Playable] (episode title as the
    /// title line, "Show · SxxEyy" as the artist line, "Season N" as the album, live flag, poster URL),
    /// exactly the mapping [NowPlayingPolicy] defines. Mirrors Apple `NowPlayingItem`.
    private val nowPlaying = NowPlayingItem.from(playable)
    private val isLive = nowPlaying.isLive

    /// The single session MediaItem, rebuilt when the off-thread poster decode lands. Artwork is fetched
    /// off the main thread by [PlayerMediaSessionEffect] and attached via [setArtwork], so a missing or
    /// slow poster never delays the card (it publishes immediately, the art attaches when it arrives),
    /// matching Apple's `beginArtwork`.
    @Volatile
    private var artworkData: ByteArray? = null
    private var mediaItemData: MediaItemData = buildItemData()
    private var lastDurationMs: Long = Long.MIN_VALUE
    private var cachedItemData: MediaItemData = mediaItemData

    /// Build the metadata + item from the current Now-Playing values (and any decoded artwork). The
    /// title/artist/album come straight from [NowPlayingPolicy], so the card reads the same as Apple's.
    private fun buildItemData(): MediaItemData {
        val builder = MediaMetadata.Builder()
            .setTitle(NowPlayingPolicy.primaryTitle(nowPlaying))
            .setArtist(NowPlayingPolicy.secondaryLine(nowPlaying))
            .setSubtitle(NowPlayingPolicy.secondaryLine(nowPlaying))
            .setAlbumTitle(NowPlayingPolicy.seasonLine(nowPlaying))
        nowPlaying.artworkUrl?.takeIf { it.isNotBlank() }
            ?.let { runCatching { builder.setArtworkUri(android.net.Uri.parse(it)) } }
        artworkData?.let { builder.setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER) }
        return MediaItemData.Builder(SESSION_ITEM_UID)
            .setMediaItem(
                MediaItem.Builder().setMediaId(playable.url).setMediaMetadata(builder.build()).build(),
            )
            .build()
    }

    /// Attach the off-thread-decoded poster and re-publish so the card shows real art. Called on the
    /// session looper (main). Mirrors Apple `artworkArrived`.
    fun setArtwork(bytes: ByteArray) {
        artworkData = bytes
        mediaItemData = buildItemData()
        lastDurationMs = Long.MIN_VALUE // force the duration cache to rebuild off the new metadata
        invalidateState()
    }

    override fun getState(): State {
        val s = engine.state.value
        val playbackState = when {
            s.hasError -> Player.STATE_IDLE
            s.hasEnded -> Player.STATE_ENDED
            // No permanent BUFFERING for a live / durationless stream: once it is actually rolling it reads
            // READY even with no known duration. Only the engine's real buffering flag buffers it now. The
            // old `durationMs <= 0L` clause pinned every durationless stream (a live feed, a debrid MKV that
            // never reports a duration) to a permanent spinner on the system card. Mirrors the intent of
            // Apple `NowPlayingPolicy.publishableDuration`.
            s.isBuffering -> Player.STATE_BUFFERING
            else -> Player.STATE_READY
        }
        // Gate the scrub / skip commands on a real, non-live duration so the system card never draws a
        // progress bar the engine will ignore. Mirrors Apple `NowPlayingPolicy.allowsScrubbing`.
        val canScrub = NowPlayingPolicy.allowsScrubbing(s.durationMs, isLive)
        return State.Builder()
            .setAvailableCommands(if (canScrub) SEEKABLE_COMMANDS else PLAYBACK_ONLY_COMMANDS)
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
        setUserPlaying(playWhenReady)
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
        // A live / durationless stream publishes NO duration (a bogus scrubbable bar otherwise), matching
        // Apple `NowPlayingPolicy.publishableDuration`.
        val publishable = NowPlayingPolicy.publishableDurationMs(durationMs, isLive)
        cachedItemData = mediaItemData
            .buildUpon()
            .setDurationUs(if (publishable != null) publishable * 1000L else C.TIME_UNSET)
            .build()
        return cachedItemData
    }

    private companion object {
        /// Stable uid for the session's single media item (SimpleBasePlayer keys items by uid).
        private const val SESSION_ITEM_UID = "vortx-player-item"

        /// 10s, matching the chrome's Replay10/Forward10 buttons and the double-tap gesture step.
        private const val SESSION_SEEK_INCREMENT_MS = 10_000L

        /// What controllers may drive with a real, seekable VOD duration: transport + seek + metadata
        /// reads. No playlist editing, no stop (Back is the app's exit gesture), no next/previous (the Up
        /// Next auto-advance is the host's flow, not a session command, and a bogus "next" button on the
        /// lockscreen that no-ops would read as broken).
        private val SEEKABLE_COMMANDS = Player.Commands.Builder()
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

        /// A LIVE / durationless stream: play/pause + metadata only. Withholding the seek commands is what
        /// stops the system card drawing a scrub bar the engine cannot honour (Apple keeps
        /// changePlaybackPosition / skip disabled for exactly these streams).
        private val PLAYBACK_ONLY_COMMANDS = Player.Commands.Builder()
            .addAll(
                Player.COMMAND_PLAY_PAUSE,
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
    setUserPlaying: (Boolean) -> Unit,
) {
    val context = LocalContext.current
    val currentSpeed by rememberUpdatedState(speed)
    DisposableEffect(engine, playable.url) {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val player = EngineSessionPlayer(engine, playable, setUserPlaying, Looper.getMainLooper())
        // Fail-soft: a session build failure (an OEM MediaSessionManager quirk) must never take
        // playback down with it; the player simply runs session-less, as it did before this file.
        val session = runCatching {
            MediaSession.Builder(context, player)
                .setId("vortx-player-${SESSION_SEQUENCE.incrementAndGet()}")
                .apply { sessionActivityIntent(context)?.let { setSessionActivity(it) } }
                .build()
        }.getOrNull()
        val nowPlaying = NowPlayingItem.from(playable)
        // The system media notification (the lockscreen / quick-settings card). Posted once the session
        // exists and re-posted on a play/pause flip + when the poster lands, so the card mirrors the live
        // engine. Fail-soft: a build / post failure (an OEM quirk, POST_NOTIFICATIONS denied) never takes
        // playback down; the session still drives headset / assistant / Android Auto without it.
        session?.let { postPlaybackNotification(context, it, nowPlaying, engine.state.value.isPaused) }
        // Every engine emission republishes through the adapter (diffed there); a play/pause flip re-posts
        // the notification so the card's transport is honest. The speed hint rides its own snapshot flow
        // because the engine does not publish speed.
        scope.launch {
            var lastPaused: Boolean? = null
            engine.state.collect { s ->
                player.publishFromEngine()
                if (session != null && s.isPaused != lastPaused) {
                    lastPaused = s.isPaused
                    postPlaybackNotification(context, session, nowPlaying, s.isPaused)
                }
            }
        }
        scope.launch { snapshotFlow { currentSpeed }.collect { player.setSpeedHint(it) } }
        // Decode the poster OFF the main thread and attach it once (Apple `beginArtwork`): a missing / slow
        // poster never delays the card, and a value-equal re-key never refetches (the URL keys the effect).
        scope.launch {
            val bytes = loadNowPlayingArtwork(context, playable.posterUrl) ?: return@launch
            player.setArtwork(bytes)
            session?.let { postPlaybackNotification(context, it, nowPlaying, engine.state.value.isPaused) }
        }
        onDispose {
            scope.cancel()
            cancelPlaybackNotification(context)
            runCatching { session?.release() }
            runCatching { player.release() }
        }
    }
}

/// Post (or refresh) the system media notification for [session] -- the lockscreen / quick-settings media
/// card. A media3 [androidx.media3.session.MediaStyleNotificationHelper.MediaStyle] binds the notification
/// to the session token, so the system card draws its transport from the session's own commands + state
/// (which is why this needs no hand-wired action PendingIntents) and its artwork from the session metadata
/// (attached off-thread by [EngineSessionPlayer.setArtwork]).
///
/// DIVERGENCE from Apple (documented deliberately): this is a composition-scoped notification, NOT a
/// standalone foreground `MediaSessionService`. VortX has no background playback (the lifecycle observer
/// pauses + drops decode at ON_STOP), so a service that outlived the UI would advertise controls for
/// playback that cannot run -- the exact reason [EngineSessionPlayer]'s scope doc gives for having no
/// service. The card therefore lives exactly as long as the player, and is cancelled on dispose.
///
/// Fail-soft at every step: no channel, POST_NOTIFICATIONS denied (API 33+), or an OEM quirk simply leaves
/// the card unshown; the session still drives headset / Bluetooth / assistant / Android Auto.
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
private fun postPlaybackNotification(
    context: Context,
    session: MediaSession,
    item: NowPlayingItem,
    isPaused: Boolean,
) {
    runCatching {
        if (!canPostNotifications(context)) return
        ensurePlaybackChannel(context)
        val builder = androidx.core.app.NotificationCompat.Builder(context, PLAYBACK_CHANNEL_ID)
            .setSmallIcon(if (isPaused) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play)
            .setContentTitle(NowPlayingPolicy.primaryTitle(item))
            .setStyle(androidx.media3.session.MediaStyleNotificationHelper.MediaStyle(session))
            .setOngoing(!isPaused)
            .setSilent(true)
            .setVisibility(androidx.core.app.NotificationCompat.VISIBILITY_PUBLIC)
        NowPlayingPolicy.secondaryLine(item)?.let { builder.setContentText(it) }
        sessionActivityIntent(context)?.let { builder.setContentIntent(it) }
        androidx.core.app.NotificationManagerCompat.from(context)
            .notify(PLAYBACK_NOTIFICATION_ID, builder.build())
    }
}

/// Remove the media card when the player closes (the card is what a viewer sees on the lockscreen; a stale
/// one after playback ends would be a bug). Best-effort, never throws.
private fun cancelPlaybackNotification(context: Context) {
    runCatching {
        androidx.core.app.NotificationManagerCompat.from(context).cancel(PLAYBACK_NOTIFICATION_ID)
    }
}

/// Create the low-importance, badge-free playback channel once (API 26+). No-op on older releases.
private fun ensurePlaybackChannel(context: Context) {
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.O) return
    val manager = context.getSystemService(android.app.NotificationManager::class.java) ?: return
    if (manager.getNotificationChannel(PLAYBACK_CHANNEL_ID) != null) return
    val channel = android.app.NotificationChannel(
        PLAYBACK_CHANNEL_ID,
        "Playback",
        android.app.NotificationManager.IMPORTANCE_LOW,
    ).apply {
        setShowBadge(false)
        lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
    }
    manager.createNotificationChannel(channel)
}

/// POST_NOTIFICATIONS is a runtime permission from API 33; below that it is granted at install. A denied
/// permission means the card simply is not shown (playback is never gated on it).
private fun canPostNotifications(context: Context): Boolean {
    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.TIRAMISU) return true
    return androidx.core.content.ContextCompat.checkSelfPermission(
        context,
        android.Manifest.permission.POST_NOTIFICATIONS,
    ) == android.content.pm.PackageManager.PERMISSION_GRANTED
}

private const val PLAYBACK_CHANNEL_ID = "vortx_playback"
private const val PLAYBACK_NOTIFICATION_ID = 0x5701

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

/// Decode the Now-Playing poster to JPEG bytes off the main thread, so the system media card / lockscreen
/// shows real art. Uses the app's shared Coil [coil3.ImageLoader] (its disk + memory caches, so a poster
/// already on screen is free) and forces a software bitmap so it can be re-encoded. Fail-soft at every
/// step: a null URL, a fetch failure, or a decode failure simply leaves the card art-less. Mirrors Apple's
/// `PosterImageLoader.load(url, maxPixel: 600)` feeding `MPMediaItemArtwork`.
private suspend fun loadNowPlayingArtwork(context: Context, url: String?): ByteArray? {
    val clean = url?.takeIf { it.isNotBlank() } ?: return null
    return withContext(Dispatchers.IO) {
        runCatching {
            val request = coil3.request.ImageRequest.Builder(context)
                .data(clean)
                .size(NOW_PLAYING_ART_MAX_PIXEL, NOW_PLAYING_ART_MAX_PIXEL)
                .allowHardware(false) // a hardware bitmap cannot be re-encoded below
                .build()
            val result = coil3.SingletonImageLoader.get(context).execute(request)
            val image = (result as? coil3.request.SuccessResult)?.image ?: return@runCatching null
            val bitmap = image.toBitmap()
            val out = java.io.ByteArrayOutputStream()
            val ok = bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 90, out)
            if (ok) out.toByteArray() else null
        }.getOrNull()
    }
}

/// Poster art is downscaled to at most this pixel edge (Apple passes `maxPixel: 600`): the system card
/// renders it small, so a full 4K poster would waste memory + XPC.
private const val NOW_PLAYING_ART_MAX_PIXEL = 600
