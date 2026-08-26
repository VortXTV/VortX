package com.vortx.android.player

import android.app.Activity
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.SystemClock
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.util.UnstableApi
import com.vortx.android.VortXApplication
import com.vortx.android.cast.CastButton
import com.vortx.android.cast.CastEligibility
import com.vortx.android.cast.CastOverlay
import com.vortx.android.cast.CastRouteChooserSheet
import com.vortx.android.cast.rememberCastManager
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.model.Episode
import com.vortx.android.model.Playable
import com.vortx.android.model.StreamSource
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.player.audio.AudioRouteMonitor
import com.vortx.android.skip.AutoSkipPolicy
import com.vortx.android.skip.SegmentResolver
import com.vortx.android.skip.SkipSegment
import com.vortx.android.skip.SkipTimestampService
import com.vortx.android.trickplay.TrickplaySession
import com.vortx.android.ui.theme.vortxGlassProminent
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/// Fullscreen player. It no longer owns a specific engine: [PlayerEngineRouter] picks the engine for
/// this [playable] (libmpv PRIMARY, ExoPlayer for Dolby Vision / Atmos passthrough and as the fail-soft
/// fallback), and this screen drives whichever engine came back through the engine-agnostic
/// [PlayerEngine] seam. The [PlayerChrome] renders [PlayerState] and calls transport methods, so it never
/// knows which engine is live.
///
/// Fail-soft: the router already demotes to ExoPlayer when [MpvEngineFactory] returns null (mpv init
/// failed, or the `play` flavor). This screen adds the SECOND safety net: if the chosen mpv engine
/// reports a hard surface-attach failure at render time, it rebuilds on the ExoPlayer engine so a broken
/// mpv surface degrades to Media3 instead of a black frame.
///
/// Dolby Vision / Atmos: NOT hand-decoded here. The ExoPlayer engine's DefaultRenderersFactory does the
/// DV -> HEVC/AVC/AV1 codec fallback and its DefaultAudioSink negotiates Atmos passthrough; that is why
/// the router routes those streams there. The DV badge in the chrome is gated on the display advertising
/// Dolby Vision (see [displaySupportsDolbyVision]), so it never promises DV on a panel that cannot present it.
// Two opt-in annotations, deliberately: kotlin.OptIn satisfies the Kotlin compiler's own experimental-API
// check; androidx.annotation.OptIn is the separate one Android Lint's UnsafeOptInUsageError looks for
// (S01 lint-config baseline surfaced this -- ExoPlayerEngine(context) below, inside an inline `remember`
// lambda, was flagged even though it's lexically inside this function).
@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(
    playable: Playable,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    emberAccent: Color = DefaultEmber,
    engineOverride: PlayerEngineRouter.Override = PlayerEngineRouter.Override.AUTO,
    /// Live position/duration (ms) callback for progress writeback. The host wires it to the engine so
    /// Continue Watching updates; a no-op by default keeps the screen usable in isolation.
    onProgress: (positionMs: Long, durationMs: Long) -> Unit = { _, _ -> },
    /// Called when the source fails unrecoverably: the host returns to the ranked source list. Defaults
    /// to [onBack] (return to the detail page, which shows the sources).
    onError: () -> Unit = onBack,
    /// Called once when playback reaches the natural END of the stream (never for a user back-out).
    /// Defaults to [onBack] so a host without an auto-advance flow keeps the old exit-to-detail
    /// behavior; the phone shell wires it to the series Up Next auto-advance instead.
    onEnded: () -> Unit = onBack,
    /// Called ONCE when the live source is judged BAD -- the engine's own hasError, the stall
    /// watchdog, or the runtime-mismatch verdict below (a file implausibly shorter than the title's
    /// expected runtime, e.g. a ~10s junk file standing in for a removed episode). The host is
    /// expected to auto-retry the next ranked source (the phone shell's bad-source ladder) WITHOUT
    /// bouncing the viewer out. Null (the default) keeps the pre-existing behavior exactly: the
    /// error overlay with its manual "Choose another source" action (the TV shell today).
    onSourceFailed: ((positionMs: Long) -> Unit)? = null,
    /// Ranked alternates and best-per-resolution choices for the in-player Sources / Quality sheets.
    /// Empty lists keep both controls hidden for trailers, downloads, and ad-hoc links.
    sourceOptions: List<StreamSource> = emptyList(),
    qualityOptions: List<Pair<String, StreamSource>> = emptyList(),
    /// Current-season episodes for the in-player EPISODES picker (series only). Empty keeps the control
    /// hidden. Picking one switches in place via [onSwitchEpisode].
    episodeOptions: List<Episode> = emptyList(),
    currentSource: StreamSource? = null,
    /// Resolve a replacement without tearing down the healthy engine. Resolution is side-effect-free; the
    /// returned commit seam runs only after this host accepts the exact session/request authority.
    onSwitchSource: (suspend (source: StreamSource) -> Result<PlayerSourceSwitchResolution>)? = null,
    /// Resolve the chosen episode's best source without tearing down the healthy engine, exactly like
    /// [onSwitchSource]. Null keeps the episode picker inert (no resolver wired).
    onSwitchEpisode: (suspend (episodeId: String) -> Result<PlayerSourceSwitchResolution>)? = null,
    /// Fired when an episode switch is ACCEPTED, so the host can advance its own history identity (a new
    /// engine playback session for the new episode) even when the replacement Playable is value-equal.
    onEpisodeSwitched: (Playable, acceptedRevision: Long) -> Unit = { _, _ -> },
    /// Fired periodically while playback rolls with the live (positionMs, durationMs), so the host can drive
    /// its next-episode PRELOAD policy (warm the next episode's source before the current one ends). Default
    /// no-op keeps the screen usable in isolation; the phone shell wires it to [NextEpisodePreloadPolicy].
    onWarmNext: (positionMs: Long, durationMs: Long) -> Unit = { _, _ -> },
    /// How many episodes auto-advanced back-to-back (with no interaction) to reach THIS playback, so the
    /// binge boundary of the "Still watching?" guard can fire. The host counts the streak across the
    /// auto-advance chain and resets it on any manual play. 0 (the default) never trips the binge boundary.
    /// Mirrors Apple `consecutiveAutoAdvances` (PlayerScreen.swift:2064).
    autoAdvanceCount: Int = 0,
    /// Fired once when the binge boundary raised the "Still watching?" prompt, so the host resets its
    /// auto-advance streak (Apple's `noteInteraction` clears `consecutiveAutoAdvances` on Continue).
    onBingePrompted: () -> Unit = {},
    /// TV-ONLY opt-ins (all default off/null, so the phone host's player is byte-for-byte unchanged).
    /// [shareLink] adds the per-stream "QR for your phone" row. [isTvPlayer] turns on the 10-foot player
    /// additions: the preferred-audio/subtitle-language + forced-policy pickers in the audio/subtitle sheets
    /// (forwarded to [PlayerChrome]) and the hidden-chrome D-pad skip pill (Select skips the segment, Back
    /// dismisses the pill without leaving the player).
    shareLink: String? = null,
    isTvPlayer: Boolean = false,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // The hosting Activity + AudioManager, resolved once: the gesture layer (window brightness,
    // stream volume), the audio-focus request, and PiP all hang off these two handles.
    val hostActivity = remember(context) { context.findActivity() }
    val audioManager = remember(context) { context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager }
    val currentOnBack by rememberUpdatedState(onBack)
    val currentOnProgress by rememberUpdatedState(onProgress)
    val currentOnError by rememberUpdatedState(onError)
    val currentOnEnded by rememberUpdatedState(onEnded)
    val currentOnSourceFailed by rememberUpdatedState(onSourceFailed)
    val currentOnSwitchSource by rememberUpdatedState(onSwitchSource)
    val currentOnSwitchEpisode by rememberUpdatedState(onSwitchEpisode)
    val currentOnEpisodeSwitched by rememberUpdatedState(onEpisodeSwitched)
    val currentOnWarmNext by rememberUpdatedState(onWarmNext)
    val sourceSwitchCoordinator = remember { PlayerSourceSwitchCoordinator() }
    val outerPlaybackSessionId = remember(playable) { sourceSwitchCoordinator.replaceOuterSession() }
    DisposableEffect(sourceSwitchCoordinator, outerPlaybackSessionId) {
        onDispose { sourceSwitchCoordinator.invalidateIfCurrent(outerPlaybackSessionId) }
    }

    // The shell's [playable] is the initial mount (and still changes for the established retry / Up Next
    // flows). A viewer's Sources/Quality pick stays INSIDE this player: keep the old engine alive while the
    // replacement resolves, then accept it atomically. [sessionKey] re-keys every source-owned effect even
    // when two rows resolve to one URL; a failed resolve leaves both the engine and key unchanged.
    var sourceSwitchState by remember(outerPlaybackSessionId) {
        mutableStateOf(
            PlayerSourceSwitchState(
                outerSessionId = outerPlaybackSessionId,
                playable = playable,
                currentSource = currentSource,
            ),
        )
    }
    val currentPlayable = sourceSwitchState.playable
    val playbackSessionKey = sourceSwitchState.sessionKey
    val subtitleContentKey = remember(playbackSessionKey) {
        subtitleOffsetContentKey(currentPlayable.mediaRef)
    }

    // LOCAL SESSION BINDING (audit AND-DL-01): a local file play (an offline download) arrives with an
    // immutable [PlaybackContext] bound by [DownloadRecord.localPlayable] -- owner/profile, content +
    // video ids, type, season/episode, title/poster, resume identity, provenance -- and a mediaRef
    // derived from THAT context, so every identity consumer below (scrobble, add-on subtitles, skip
    // segments, trickplay keys, auto-skip memory) binds to the downloaded title itself. What a local
    // session must NEVER do is feed host callbacks that resolve identity from AMBIENT state: the
    // shell's detail ViewModel may still hold a previously streamed title A when downloaded B plays,
    // and B's end/failure/preload ticks would then advance or retry A. So for a local session this
    // screen routes its natural end to a plain exit (the TV shell's long-standing behavior) and keeps
    // the preload + bad-source-retry ladders dormant; a context-less local file (never produced today,
    // defensive only) is treated the same fail-safe way.
    val isLocalSession = isLocalFilePlayback(currentPlayable)

    // Chrome-owned view state (not engine state): the aspect/zoom mode passed to the surface, and the
    // current playback speed reflected in the speed control. The aspect mode is seeded from the persisted
    // choice (Apple `stremiox.videoSize`) rather than always Fit, so the viewer's last pick is restored on
    // every title instead of snapping back. Read per session so a change made mid-session sticks next time.
    var scaleMode by remember(playbackSessionKey) {
        mutableStateOf(com.vortx.android.player.extras.AspectRatioSetting.current(context))
    }
    var speed by remember(playbackSessionKey) { mutableStateOf(1.0f) }
    // Whether the "contribute a skip time" editor overlay is open. Reset per playback session.
    var showSkipEditor by remember(playbackSessionKey) { mutableStateOf(false) }
    var subtitleDelaySeconds by remember(playbackSessionKey) {
        mutableStateOf(SubtitleOffsetMemory.savedOffset(context, subtitleContentKey) ?: 0.0)
    }
    var subtitleStyle by remember(playbackSessionKey) { mutableStateOf(SubtitleStyle.current(context)) }
    var audioDelaySeconds by remember(playbackSessionKey) { mutableStateOf(0.0) }
    var audioOutputMode by remember(playbackSessionKey) { mutableStateOf(AudioOutputMode.current(context)) }
    // Hardware/software decode (mpv-only). Defaults to hardware (mediacodec, the DV/HDR passthrough path);
    // Software is the escape hatch for green / garbled frames. Host-tracked so the checkmark stays reactive.
    var hardwareDecoding by remember(playbackSessionKey) { mutableStateOf(true) }
    // Sleep timer: a timed auto-pause (minutes) or a stop at the end of the current episode. Both reset on a
    // new stream (keyed on the playback session). See the timer effect and the end-of-stream gate below.
    var sleepMinutes by remember(playbackSessionKey) { mutableStateOf<Int?>(null) }
    var sleepAtEpisodeEnd by remember(playbackSessionKey) { mutableStateOf(false) }

    // SEEK STEP (Apple `stremiox.seekStep`): the ms step every discrete relative seek uses -- the transport
    // +/- buttons, the double-tap gesture, the TV remote FF/RW keys, and the hidden-chrome D-pad nudge.
    // Read once per session; a change takes effect on the next play, like Apple's @AppStorage.
    val seekStepMs = remember(playbackSessionKey) { SeekStepSetting.stepMs(context) }
    val seekStepSeconds = remember(seekStepMs) { (seekStepMs / 1000L).toInt() }

    // DEFAULT VOLUME + MUTE (Apple `stremiox.playerVolume` / `stremiox.playerMuted`), host-tracked so the
    // in-player slider stays reactive. Applied to the live engine at load (below); the slider / mute button
    // and the swipe gesture write through here and persist, so the level rides the same key Apple uses.
    var playerVolume by remember(playbackSessionKey) { mutableStateOf(PlayerVolumeSettings.volume(context)) }
    var playerMuted by remember(playbackSessionKey) { mutableStateOf(PlayerVolumeSettings.muted(context)) }

    // STILL WATCHING (Apple `vortx.stillWatchingPrompt` / `vortx.stillWatchingAfterEpisodes`). The prompt is
    // up (playback paused, awaiting Continue / Stop); the idle deadline is pushed forward on every
    // interaction. Read once per session, like Apple's @AppStorage.
    val stillWatchingEnabled = remember(playbackSessionKey) { StillWatchingSettings.promptEnabled(context) }
    val stillWatchingAfterEpisodes = remember(playbackSessionKey) { StillWatchingSettings.afterEpisodes(context) }
    var stillWatchingPrompt by remember(playbackSessionKey) { mutableStateOf(false) }
    // Wall-clock (elapsedRealtime) idle deadline, a single-element holder so re-arming it never itself
    // recomposes. Mirrors Apple's `idleDeadline`.
    val idleDeadline = remember(playbackSessionKey) {
        longArrayOf(SystemClock.elapsedRealtime() + StillWatchingSettings.IDLE_TIMEOUT_MS)
    }

    // HIDDEN-CHROME D-PAD SEEK NUDGE: while the chrome is hidden, Left/Right does a small seek and shows a
    // floating time pill (not the whole transport bar). [seekNudgeTargetMs] is the predicted target the pill
    // shows; [seekNudgeTick] re-arms its auto-hide. Mirrors Apple's `hiddenSeek` floating-time affordance.
    var seekNudgeTargetMs by remember(playbackSessionKey) { mutableStateOf<Long?>(null) }
    var seekNudgeTick by remember(playbackSessionKey) { mutableStateOf(0) }

    // CONTROLS AUTO-HIDE. The chrome (top scrim + title + transport bar) previously had no visibility
    // state at all, so it was drawn permanently over the video. Now: visible on entry, auto-hidden after
    // [CONTROLS_AUTO_HIDE_MS] of playback, re-shown (with the timer reset) by any interaction -- a tap on
    // bare video toggles it, the double-tap seek re-shows it, every transport/track action re-arms it, and
    // on TV any D-pad press while hidden re-reveals (consumed, so a blind press never fires an invisible
    // control). The error overlay and the selection sheets are NOT gated (see PlayerChrome).
    var controlsVisible by remember(playbackSessionKey) { mutableStateOf(true) }
    // Monotonic interaction counter: bumping it restarts the auto-hide countdown without toggling
    // visibility (the timer effect keys on it).
    var controlsInteractionTick by remember(playbackSessionKey) { mutableStateOf(0) }
    fun showControls() {
        controlsVisible = true
        controlsInteractionTick++
    }

    // PLAYER LOCK (touch-lock). Engaged from the chrome's lock control: the chrome hides and every
    // tap/double-tap/key is swallowed so nothing mid-film seeks or pauses by accident (handing the
    // phone over, pocketing it, a sprawled thumb). The ONLY interactive surface while locked is a
    // small glass "Tap to unlock" affordance that a bare tap reveals (auto-hidden again after
    // [UNLOCK_HINT_AUTO_HIDE_MS]); unlocking restores the normal chrome. Hardware Back deliberately
    // keeps meaning "leave the player": the lock guards against accidental TOUCH, and trapping the
    // viewer inside a locked player would be worse than any accidental exit.
    var controlsLocked by remember(playbackSessionKey) { mutableStateOf(false) }
    var unlockHintVisible by remember(playbackSessionKey) { mutableStateOf(false) }
    var unlockHintTick by remember(playbackSessionKey) { mutableStateOf(0) }
    fun revealUnlockHint() {
        unlockHintVisible = true
        unlockHintTick++
    }

    // Force-to-ExoPlayer latch: flipped when the mpv engine reports a surface failure, so the remember
    // key changes and the engine is rebuilt on ExoPlayer. Keyed alongside the playback session so a
    // switched stream starts fresh.
    var forceExoPlayer by remember(playbackSessionKey) { mutableStateOf(false) }

    // IN-PLAYER ENGINE SWITCH (mpv <-> ExoPlayer). The viewer's tri-state preference (auto / mpv /
    // ExoPlayer), initialized from the host's [engineOverride] and re-picked from the Player Engine sheet.
    // Changing it rekeys the engine build below so the engine rebuilds on the chosen player. Distinct from
    // [forceExoPlayer], which is the involuntary surface-fail demotion.
    var enginePreference by remember(playbackSessionKey) { mutableStateOf(engineOverride) }
    // Position (ms) to resume at on the NEXT rebuild caused by a USER engine switch, so the swap continues
    // where the film is rather than restarting at the source's resume point (that is the surface-fail
    // path's behavior, which is left unchanged). -1 = no user switch pending. A plain array, not Compose
    // state, so writing it never itself triggers recomposition; the paired [enginePreference] flip does.
    val engineSwitchResumeMs = remember(playbackSessionKey) { longArrayOf(-1L) }

    // ENGINE, built OFF the composition thread. The old `remember { ... .also { it.load() } }` ran the
    // whole build synchronously in composition: for the libmpv route that is System.loadLibrary +
    // native context create + mpv_initialize + the full option apply on the MAIN thread -- jank (and an
    // ANR window) at every open. Now the route is decided first (pure logic), and:
    //   - the mpv route builds + loads on a background dispatcher (the mpv handle is thread-safe by
    //     contract; its callbacks already arrive on native worker threads);
    //   - the ExoPlayer route stays on the main thread, REQUIRED: Media3 binds the player to the
    //     constructing thread's looper and throws on cross-thread access, and Exo's own build is light.
    // Until the engine lands, the composition shows the connecting state below (the same spinner the
    // chrome shows pre-first-frame), never a dead black frame.
    //
    // Ownership is race-free via [engineHolder]: the built engine is set inside the build block (no
    // suspension point between create and set), and every release path -- the keyed dispose below, the
    // lifecycle ON_DESTROY, and the "composition left while still building" tail -- claims it with ONE
    // atomic getAndSet(null), so exactly one release ever runs no matter how teardown races the build.
    val engineHolder = remember(playbackSessionKey, forceExoPlayer, enginePreference) { AtomicReference<PlayerEngine?>(null) }
    var builtEngine by remember(playbackSessionKey, forceExoPlayer, enginePreference) { mutableStateOf<PlayerEngine?>(null) }
    LaunchedEffect(playbackSessionKey, forceExoPlayer, enginePreference) {
        // A user engine switch resumes at the live position; every other rebuild loads the source at its
        // own resume point. Consume the pending resume once so a later surface-fail rebuild is unaffected.
        val resumeAt = engineSwitchResumeMs[0]
        engineSwitchResumeMs[0] = -1L
        val playableForEngine =
            if (resumeAt >= 0L) currentPlayable.copy(startPositionMs = resumeAt) else currentPlayable
        val wantsMpv = !forceExoPlayer &&
            PlayerEngineRouter.choose(currentPlayable, enginePreference) == PlayerEngineRouter.Engine.MPV
        val engine: PlayerEngine = if (wantsMpv) {
            // NonCancellable: a half-initialized native mpv context must never be abandoned mid-build
            // (cancellation would leak it un-releasable); the block always completes, and the isActive
            // check below hands a build that lost its composition straight to release.
            withContext(Dispatchers.Default + NonCancellable) {
                MpvEngineFactory.create(context)?.also {
                    engineHolder.set(it)
                    it.load(playableForEngine)
                }
            } ?: ExoPlayerEngine(context).also {
                // Fail-soft fallback (mpv unavailable), on the main thread per the Media3 contract.
                engineHolder.set(it)
                it.load(playableForEngine)
            }
        } else {
            ExoPlayerEngine(context).also {
                engineHolder.set(it)
                it.load(playableForEngine)
            }
        }
        if (!isActive) {
            // The player left composition while the engine was still initializing; the dispose below
            // may already have run (and found the holder empty), so this tail owns the release.
            engineHolder.getAndSet(null)?.release()
            return@LaunchedEffect
        }
        builtEngine = engine
    }
    DisposableEffect(playbackSessionKey, forceExoPlayer, enginePreference) {
        onDispose { engineHolder.getAndSet(null)?.release() }
    }

    // PLAYER ORIENTATION LOCK + IMMERSIVE MODE. A video player presents landscape: request sensor
    // landscape on the hosting Activity while this screen is in composition, and restore the PRIOR
    // request on exit so the browse shell keeps its own orientation freedom (the player is the ONLY
    // surface locked; the app is not). The manifest's configChanges=orientation|screenSize means this
    // flip resizes the surface in place instead of recreating the Activity, so the engine survives the
    // rotation. Alongside it, hide the system bars (swipe reveals them transiently) for a true
    // fullscreen frame, restored on exit. On Android TV both calls are harmless no-ops (the panel is
    // already landscape and TVs show no bars). Keyed on Unit: enter/exit of the player, not per engine.
    DisposableEffect(Unit) {
        val activity = context.findActivity()
        val previousOrientation = activity?.requestedOrientation
            ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        val insetsController = activity?.window?.let { w ->
            WindowInsetsControllerCompat(w, w.decorView).apply {
                systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                hide(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose {
            insetsController?.show(WindowInsetsCompat.Type.systemBars())
            activity?.requestedOrientation = previousOrientation
            // The brightness gesture only ever overrides the WINDOW level; hand the window back to
            // the system setting so the browse shell never inherits a mid-film dimming.
            clearWindowBrightness(activity)
        }
    }

    // Engine still initializing (the off-main build above): hold the fullscreen frame with the same
    // centered spinner + "Connecting" the chrome shows pre-first-frame, so the open is one continuous
    // loading state instead of a blank flash. Hardware/gesture Back still works (the host's BackHandler
    // wraps this screen). Deliberately AFTER the orientation/immersive effect so the connecting frame is
    // already landscape + edge-to-edge.
    val engine = builtEngine
    if (engine == null) {
        Box(
            modifier = modifier
                .fillMaxSize()
                .background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = emberAccent, modifier = Modifier.size(44.dp))
                Text(
                    text = "Connecting...",
                    color = Color.White.copy(alpha = 0.85f),
                    fontWeight = FontWeight.Medium,
                    fontSize = 13.sp,
                )
            }
        }
        return
    }

    // Drive the engine against the host lifecycle: drop decode / pause when backgrounded, resume when it
    // returns, release on destroy. Matches the Apple player's enterBackground/enterForeground.
    DisposableEffect(lifecycleOwner, engine) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> engine.onEnterBackground()
                Lifecycle.Event.ON_START -> engine.onEnterForeground()
                // Release through the holder's single atomic claim, so a destroy-then-dispose pair can
                // never double-release the same native engine.
                Lifecycle.Event.ON_DESTROY -> engineHolder.getAndSet(null)?.release()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    // WHY audit 05.4: player-scoped runtime pressure must reach the live engine, not only the next load.
    // UI_HIDDEN alone is not pressure; RUNNING_LOW/CRITICAL and background pressure levels shed once.
    DisposableEffect(context, engine) {
        val appContext = context.applicationContext
        val callbacks = object : ComponentCallbacks2 {
            override fun onTrimMemory(level: Int) {
                if (
                    level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
                    level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL ||
                    level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND
                ) {
                    engine.onTrimMemory(level)
                }
            }

            override fun onLowMemory() {
                engine.onTrimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)
            }

            override fun onConfigurationChanged(newConfig: Configuration) = Unit
        }
        appContext.registerComponentCallbacks(callbacks)
        onDispose { appContext.unregisterComponentCallbacks(callbacks) }
    }

    // REAPPLY THE AUDIO POLICY WHEN THE ROUTE CHANGES MID-PLAY (audit 08.1). The policy ran at init and
    // explicit picks only, so plugging in or dropping BT/WiFi/headphones kept the stale output mode until
    // the next manual action. The monitor coalesces device add/remove + BECOMING_NOISY bursts into one
    // callback; we re-run the same engine seam the picker uses, which re-reads the current route.
    DisposableEffect(lifecycleOwner, engine) {
        val routeMonitor = AudioRouteMonitor(context) {
            if (engine.audioOutputModeAvailable) {
                engine.setAudioOutputMode(audioOutputMode)
            }
        }
        lifecycleOwner.lifecycle.addObserver(routeMonitor)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(routeMonitor)
            routeMonitor.stop()
        }
    }

    // AUTO-ROTATE TO LANDSCAPE (Apple `stremiox.autoLandscapeInPlayer`, default on). On a phone, opening a
    // non-trailer stream turns the device to landscape to match the video (following the sensor between the
    // two landscape orientations), and restores the previous orientation on exit. A no-op on TV, which is
    // always landscape, and for trailers, exactly like Apple's `forceLandscape` gate.
    DisposableEffect(currentPlayable.isTrailer) {
        val activity = activityOf(context)
        val isTv = context.packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK)
        if (
            activity != null && !isTv && !currentPlayable.isTrailer &&
            com.vortx.android.player.extras.AutoLandscapeSetting.isEnabled(context)
        ) {
            val previous = activity.requestedOrientation
            activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            onDispose { activity.requestedOrientation = previous }
        } else {
            onDispose { }
        }
    }

    // MATCH FRAME RATE (AFR). When enabled, switch the display mode to match the source's frame rate once
    // the engine reports it, and revert on player exit. The controller polls the live engine for the rate
    // and is a fail-soft no-op on a panel that exposes no matching mode (phones), so this single hook is
    // safe on every device. Keyed on the engine so a source/engine switch re-matches for the new stream.
    // Mirrors the Apple TV HDRDisplayMode Match-Frame-Rate path; same preference key across all apps.
    // Held outside the effect so the watchdog / trickplay samplers below can read the settle window;
    // same atomic-holder pattern as engineHolder (no recomposition on AFR state).
    val afrHolder = remember { AtomicReference<AfrController?>(null) }
    DisposableEffect(engine, hostActivity) {
        val activity = hostActivity
        val controller = if (activity != null && MatchFrameRateSetting.isEnabled(context)) {
            AfrController(activity).also { it.start(engine) }
        } else {
            null
        }
        afrHolder.set(controller)
        onDispose { controller?.stop(); afrHolder.set(null) }
    }

    val playerState by engine.state.collectAsStateWithLifecycle()
    val latestState by rememberUpdatedState(playerState)

    // DEFAULT VOLUME + MUTE applied to the live engine at load (Apple `applyPersistedVolume`): the mount
    // begins at the engine default (100%), so restore the viewer's chosen level. Keyed on the engine so a
    // source switch / fail-soft demotion (which re-mount the engine) re-applies it. Idempotent per engine.
    LaunchedEffect(engine) {
        engine.setVolume(playerVolume)
        engine.setMuted(playerMuted)
    }
    // Set the live volume from the slider / swipe (0..100), persist it, and un-mute on any raise above 0
    // (moving the control is an intent to hear audio). Mirrors Apple `setPlayerVolume`.
    fun setPlayerVolume(v: Double) {
        val clamped = v.coerceIn(0.0, 100.0)
        playerVolume = clamped
        engine.setVolume(clamped)
        PlayerVolumeSettings.setVolume(context, clamped)
        if (clamped > 0.0 && playerMuted) {
            playerMuted = false
            engine.setMuted(false)
            PlayerVolumeSettings.setMuted(context, false)
        }
    }
    // Toggle mute on the live engine + persist; unmuting to a 0 level bumps to full so audio is actually
    // heard (Apple `togglePlayerMute`).
    fun togglePlayerMute() {
        val next = !playerMuted
        playerMuted = next
        engine.setMuted(next)
        PlayerVolumeSettings.setMuted(context, next)
        if (!next && playerVolume <= 0.0) {
            playerVolume = 100.0
            engine.setVolume(100.0)
            PlayerVolumeSettings.setVolume(context, 100.0)
        }
    }

    // STILL WATCHING re-arm: every interaction (any showControls / D-pad / transport action bumps
    // [controlsInteractionTick]) pushes the idle deadline forward, so an attended session never trips the
    // prompt. Mirrors Apple `noteInteraction`.
    LaunchedEffect(controlsInteractionTick) {
        idleDeadline[0] = SystemClock.elapsedRealtime() + StillWatchingSettings.IDLE_TIMEOUT_MS
    }
    // BINGE BOUNDARY: this playback was reached by N back-to-back auto-advances with no interaction, so
    // pause and ask instead of rolling on. Runs once at mount; the host resets its streak via
    // [onBingePrompted]. Mirrors Apple presenting the prompt at the binge boundary (PlayerScreen.swift:2065).
    LaunchedEffect(playbackSessionKey) {
        if (StillWatchingPolicy.shouldPromptOnBinge(stillWatchingEnabled, autoAdvanceCount, stillWatchingAfterEpisodes)) {
            onBingePrompted()
            runCatching { engine.pause() }
            stillWatchingPrompt = true
        }
    }
    // GOOGLE CAST (the CAST lane, Android's AirPlay equivalent). Conceptually mirrors the Apple AirPlay
    // handoff: while a receiver is connected the local engine YIELDS (pauses, so it stops decoding and
    // consuming the source), the current stream (URL + subtitles + start position) plays on the receiver,
    // and on disconnect local playback RESUMES where the receiver left off. Torrents are gated OUT of
    // casting (loopback streaming-server URLs a receiver cannot reach), exactly as the router keeps them on
    // libmpv. All cast machinery lives in com.vortx.android.cast; this host block is the minimal seam.
    val castManager = rememberCastManager()
    val castState by castManager.state.collectAsStateWithLifecycle()
    var castChooserOpen by remember(playbackSessionKey) { mutableStateOf(false) }
    val streamCastable = CastEligibility.isCastable(currentPlayable)
    // Keep the manager aimed at the current stream with a LIVE position provider, so a session started from
    // our chooser loads exactly where local playback is, and an in-player episode/source switch reloads the
    // receiver. A non-castable stream clears it so nothing stale is ever cast.
    LaunchedEffect(castManager, currentPlayable, streamCastable) {
        castManager.setNowPlaying(if (streamCastable) currentPlayable else null) {
            latestState.positionMs.coerceAtLeast(0L)
        }
    }
    // Local playback yields to / resumes from the receiver. The [wasCasting] latch makes resume fire ONLY
    // after an actual cast, so the initial (disconnected) composition never spuriously seeks or plays.
    var wasCasting by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(castState.isConnected) {
        if (castState.isConnected) {
            wasCasting = true
            engine.pause()
        } else if (wasCasting) {
            wasCasting = false
            val resumeAt = castManager.lastKnownPositionMs
            if (resumeAt > 0L) engine.seekTo(resumeAt)
            engine.play()
        }
    }
    // Record progress WHILE casting through the SAME per-profile onProgress path the local engine uses:
    // casting must not bypass watch history. The local progress writer is dormant here (its engine is
    // paused), so this is the only writer while connected, and it never runs for a trailer.
    LaunchedEffect(castState.isConnected, currentPlayable.isTrailer) {
        if (!castState.isConnected || currentPlayable.isTrailer) return@LaunchedEffect
        while (isActive) {
            val s = castManager.state.value
            if (s.durationMs > 0L && !s.isPaused) currentOnProgress(s.positionMs, s.durationMs)
            delay(CAST_PROGRESS_WRITEBACK_MS)
        }
    }

    // Keying the resolver job by the exact authority cancels it when the outer playback session or request
    // changes. The token check below is the authoritative defense if a resolver ignores cancellation.
    val pendingSourceSwitch = sourceSwitchState.pendingSwitch
    LaunchedEffect(pendingSourceSwitch?.authority) {
        val pending = pendingSourceSwitch ?: return@LaunchedEffect
        val resolver = currentOnSwitchSource
        resolveAndApplyPlayerSourceSwitch(
            coordinator = sourceSwitchCoordinator,
            pending = pending,
            resolver = { source -> resolver?.invoke(source) ?: Result.failure(IllegalStateException()) },
            currentState = { sourceSwitchState },
            latestPositionMs = { latestState.positionMs },
            publishState = { sourceSwitchState = it },
        )
    }
    // In-player EPISODE switch resolver: same coordinator/authority machinery as the source switch, but
    // the accepted episode starts from the top and notifies the host so it opens a fresh history session.
    val pendingEpisodeSwitch = sourceSwitchState.pendingEpisodeSwitch
    LaunchedEffect(pendingEpisodeSwitch?.authority) {
        val pending = pendingEpisodeSwitch ?: return@LaunchedEffect
        val resolver = currentOnSwitchEpisode
        resolveAndApplyPlayerEpisodeSwitch(
            coordinator = sourceSwitchCoordinator,
            pending = pending,
            resolver = { episode -> resolver?.invoke(episode.id) ?: Result.failure(IllegalStateException()) },
            currentState = { sourceSwitchState },
            publishState = { accepted ->
                val previous = sourceSwitchState
                sourceSwitchState = accepted
                acceptedEpisodeReplacement(previous, accepted)?.let { replacement ->
                    currentOnEpisodeSwitched(replacement.playable, replacement.revision)
                }
            },
        )
    }
    var chapters by remember(engine) { mutableStateOf<List<PlayerChapter>>(emptyList()) }
    LaunchedEffect(engine, playerState.durationMs > 0L) {
        if (playerState.durationMs <= 0L || chapters.isNotEmpty()) return@LaunchedEffect
        repeat(CHAPTER_READ_ATTEMPTS) { attempt ->
            val loaded = normalizePlayerChapters(engine.chapters())
            if (loaded.isNotEmpty()) {
                chapters = loaded
                return@LaunchedEffect
            }
            if (attempt + 1 < CHAPTER_READ_ATTEMPTS) delay(CHAPTER_READ_RETRY_MS)
        }
    }

    // Re-apply player-local controls when the live engine instance changes during a fail-soft demotion.
    // The new engine advertises its capabilities, so unsupported offsets remain honest no-ops.
    LaunchedEffect(engine) {
        if (engine.subtitleDelayAvailable && subtitleDelaySeconds != 0.0) {
            engine.setSubtitleDelay(subtitleDelaySeconds)
        }
        if (engine.audioDelayAvailable && audioDelaySeconds != 0.0) {
            engine.setAudioDelay(audioDelaySeconds)
        }
        if (engine.audioOutputModeAvailable) {
            engine.setAudioOutputMode(audioOutputMode)
        }
        // Carry a chosen software-decode escape hatch across a fail-soft demotion / engine switch; the new
        // engine advertises whether it supports the toggle, so a rebuild to ExoPlayer is a safe no-op.
        if (engine.hardwareDecodingAvailable && !hardwareDecoding) {
            engine.setHardwareDecoding(false)
        }
    }

    // SLEEP TIMER (timed leg). When armed for a number of minutes, pause playback once after that time (only
    // if it is still rolling) then disarm. The End-of-episode leg is handled at the end-of-stream gate
    // below, not here. Keyed on the session so a new stream clears any running countdown.
    LaunchedEffect(sleepMinutes, playbackSessionKey) {
        val minutes = sleepMinutes ?: return@LaunchedEffect
        delay(minutes * 60_000L)
        if (!latestState.isPaused) engine.pause()
        sleepMinutes = null
    }

    // STALL / START WATCHDOG (engine-agnostic). Neither engine has a timeout of its own for a source
    // that connects but never delivers (or stops delivering) data: mpv's `paused-for-cache` can sit
    // true forever with no error event, which used to mean an infinite silent black frame. This loop
    // samples the transport once a second and trips [stallError] -- rendered through the chrome as the
    // SAME error overlay + retry path the engines' own hasError drives -- when either bound passes with
    // no position advance:
    //   - [WATCHDOG_START_TIMEOUT_MS] before playback ever advanced (the source never produced data);
    //   - the tighter [WATCHDOG_STALL_TIMEOUT_MS] once it had (a mid-stream stall that never recovers).
    // A user pause resets the clock (holding position is then intent, not failure), a terminal
    // error/ended state suspends it, and any position advance both re-arms the clock AND clears a
    // previously tripped verdict, so a stream that recovers on its own heals back to normal playback.
    var stallError by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(engine, playbackSessionKey) {
        var lastPositionMs = -1L
        var lastProgressAt = SystemClock.elapsedRealtime()
        var everAdvanced = false
        while (true) {
            delay(WATCHDOG_POLL_MS)
            val s = latestState
            val now = SystemClock.elapsedRealtime()
            if (s.hasError || s.hasEnded || s.isPaused) {
                lastProgressAt = now
                continue
            }
            // AFR SETTLE GATE (audit 05.6): during a display-mode relock no new frames arrive; that is
            // hardware transition, not a dead source. Hold the clock open instead of tripping the bound.
            if (afrHolder.get()?.isSettling() == true) {
                lastProgressAt = now
                continue
            }
            if (s.positionMs != lastPositionMs) {
                // First sample just seeds the baseline; only a CHANGE from a real prior sample proves
                // data flowed (so a resume-seek jump does not count as playback by itself).
                if (lastPositionMs >= 0L) everAdvanced = true
                lastPositionMs = s.positionMs
                lastProgressAt = now
                if (stallError) stallError = false
                continue
            }
            val bound = if (everAdvanced) WATCHDOG_STALL_TIMEOUT_MS else WATCHDOG_START_TIMEOUT_MS
            if (now - lastProgressAt >= bound) stallError = true
        }
    }
    // RUNTIME-MISMATCH = BAD SOURCE (the trust fix). "The file ended" must not mean "the episode was
    // watched": a removed/not-in-debrid episode often resolves to a ~10s junk/sample file that plays
    // cleanly to EOF, which used to mark the episode watched and auto-advance past it. The ground
    // truth is [Playable.expectedDurationMs] (the catalog metadata runtime, attached at resolve
    // time); the file's own demuxed duration is compared against it via [isJunkDuration]:
    //   - EARLY: the moment the engine reports a real duration (available once demuxed, well before
    //     the junk finishes playing), an implausibly short file is condemned on the spot -- the 10s
    //     ideally never really plays. The engine is paused so the junk can't keep rolling (and can't
    //     reach EOF) while the host swaps sources.
    //   - EOF BACKSTOP: inside the ended dispatch below -- an EOF whose playhead sits far below the
    //     expected runtime (a file that LIED about its duration, then ended early) is the same
    //     verdict, applied before the ended signal can reach the host.
    // With NO expected runtime (ad-hoc plays, downloads, live) the check falls back to a conservative
    // absolute floor: nothing feature-length is under [JUNK_DURATION_FLOOR_MS]. Trailers are exempt
    // (short by design), and a live stream never reports a positive duration, so neither can trip it.
    // The verdict is terminal for this file by construction (metadata and the demuxed length cannot
    // change), so unlike [stallError] it never self-clears. A [Playable.userForcedSource] play (the
    // viewer's own pick off the manual fallback) is exempt from the VERDICT -- their warned, explicit
    // choice must play -- while the never-poison writeback gates below stay in force regardless.
    var runtimeMismatch by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(playerState.durationMs, playbackSessionKey) {
        if (runtimeMismatch || currentPlayable.userForcedSource) return@LaunchedEffect
        val fileMs = latestState.durationMs
        if (fileMs <= 0L) return@LaunchedEffect
        if (isJunkDuration(fileMs, currentPlayable)) runtimeMismatch = true
    }
    // Stop the condemned file immediately: pausing keeps it from playing (or EOF-ing) under the
    // error surface while the host's retry ladder resolves the next source. Only the mismatch pauses
    // here -- an engine error is already dead, and a stall verdict may still self-heal (see the
    // watchdog above), so neither is touched (the #76 semantics stay exactly as they were).
    LaunchedEffect(runtimeMismatch) {
        if (runtimeMismatch) runCatching { engine.pause() }
    }

    // The one error verdict everything downstream renders and gates on: the engine's own hasError OR
    // the watchdog's stall verdict OR the runtime-mismatch verdict.
    val effectiveError = playerState.hasError || stallError || runtimeMismatch

    // STILL WATCHING idle guard: a single long-lived poll re-checks the deadline; when the session looks
    // unattended AND is actually playing (never paused / buffering / errored / already-prompting), pause and
    // raise the prompt. Mirrors Apple `startIdleWatch` / `maybePromptStillWatching`.
    LaunchedEffect(playbackSessionKey) {
        while (true) {
            delay(StillWatchingSettings.IDLE_POLL_MS)
            val s = latestState
            val shouldPrompt = StillWatchingPolicy.shouldPromptOnIdle(
                enabled = stillWatchingEnabled,
                alreadyPrompting = stillWatchingPrompt,
                // A duration or a non-zero position both prove real playback started (mpv/ExoPlayer publish
                // one or the other once the first frame lands).
                hasStartedPlaying = s.durationMs > 0L || s.positionMs > 0L,
                isPaused = s.isPaused,
                isBuffering = s.isBuffering,
                hasError = effectiveError,
                nowMs = SystemClock.elapsedRealtime(),
                idleDeadlineMs = idleDeadline[0],
            )
            if (shouldPrompt) {
                runCatching { engine.pause() }
                stillWatchingPrompt = true
            }
        }
    }

    // PICTURE-IN-PICTURE (issue #77). The handle keeps the hosting activity's PiP params live
    // (aspect ratio from the real video size, auto-enter armed only while actually rolling, the
    // play/pause RemoteAction tracking the paused state) and reports [PlayerPipHandle.isInPip] so
    // every touch surface below can vacate the tiny window. Home-press entry is auto-enter on S+
    // and MainActivity's onUserLeaveHint -> PlayerPipBridge on 26-30; the chrome's PiP button is
    // the explicit entry. Fail-soft: an unsupported device/host yields supported=false and the
    // player renders exactly as before.
    val pip = rememberPlayerPip(
        engine = engine,
        isActivelyPlaying = !playerState.isPaused && !playerState.hasEnded && !effectiveError,
        isPaused = playerState.isPaused,
        durationKnown = playerState.durationMs > 0L,
    )
    // Crossing the PiP boundary: entering drops the chrome + any live gesture HUD (dead pixels in
    // the small window); expanding back restores the controls so the viewer lands oriented.
    var gestureHud by remember(playbackSessionKey) { mutableStateOf<PlayerGestureHud?>(null) }
    LaunchedEffect(pip.isInPip) {
        if (pip.isInPip) {
            controlsVisible = false
            gestureHud = null
        } else {
            showControls()
        }
    }

    // System MediaSession over the live engine: headset/Bluetooth transport, the Android TV
    // now-playing row, assistant play/pause. Scoped to this composition (no background playback
    // exists to outlive it); rebuilt with the engine on a mid-session ExoPlayer fallback.
    PlayerMediaSessionEffect(engine = engine, playable = currentPlayable, speed = speed)

    // BAD-SOURCE DISPATCH: hand the verdict to the host's auto-retry ladder exactly once per source.
    // Every bad-source class funnels through here -- a dead link (hasError), a silent stall
    // (stallError), a wrong/junk file (runtimeMismatch) -- so the ladder is the single recovery
    // path. With no [onSourceFailed] wired this is inert and the chrome's error overlay + manual
    // "Choose another source" behavior stays available.
    // A LOCAL session never feeds the ladder: the host's resolver belongs to whatever title its
    // detail surface holds, which for a download play can be a DIFFERENT streamed title -- retrying
    // it would resolve and play foreign sources over this session's file (AND-DL-01). The error
    // overlay remains the recovery surface.
    var sourceFailureDispatched by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(effectiveError) {
        if (!effectiveError || sourceFailureDispatched || isLocalSession) return@LaunchedEffect
        val dispatch = currentOnSourceFailed ?: return@LaunchedEffect
        sourceFailureDispatched = true
        dispatch(latestState.positionMs.coerceAtLeast(0L))
    }

    // The auto-hide countdown: runs only while the controls are up and playback is actually rolling.
    // Paused, buffering, or errored playback keeps the controls on screen (hiding them over a stall or a
    // dead frame would look like a hang); any state flip or interaction tick restarts the countdown.
    LaunchedEffect(controlsVisible, controlsInteractionTick, playerState.isPaused, playerState.isBuffering, effectiveError) {
        if (!controlsVisible || playerState.isPaused || playerState.isBuffering || effectiveError) return@LaunchedEffect
        delay(CONTROLS_AUTO_HIDE_MS)
        controlsVisible = false
    }

    // The unlock affordance's own auto-hide: while locked, the small "Tap to unlock" pill stays up a
    // couple of seconds after each reveal (any tap/key re-reveals + re-arms via [unlockHintTick]),
    // then drops back to clean full-screen video.
    LaunchedEffect(controlsLocked, unlockHintVisible, unlockHintTick) {
        if (!controlsLocked || !unlockHintVisible) return@LaunchedEffect
        delay(UNLOCK_HINT_AUTO_HIDE_MS)
        unlockHintVisible = false
    }

    // The hidden-chrome D-pad seek pill auto-hides shortly after each nudge; a fresh nudge re-arms it via
    // [seekNudgeTick]. Kept brief -- the pill is a quick confirmation, not persistent chrome.
    LaunchedEffect(seekNudgeTick) {
        if (seekNudgeTargetMs == null) return@LaunchedEffect
        delay(SEEK_NUDGE_PILL_AUTO_HIDE_MS)
        seekNudgeTargetMs = null
    }

    // ADD-ON SUBTITLES (the Android port of Apple SubtitleAddons.swift:37 `installedSources` +
    // :54 `fetch`): once per load, union the installed subtitle-capable add-ons (minus any the
    // active profile turned off) and fetch their external tracks for THIS title, keyed by the
    // playable's imdb identity. Fail-soft at every step -- a trailer, an id-less playable, no
    // subtitle add-ons installed, or a flaky add-on simply leaves the sheet's add-on section empty.
    // The results list in the chrome's subtitle sheet under the embedded tracks; picking one mounts
    // it on the live engine (mpv `sub-add` / the ExoPlayer side-loaded track rebuild) and
    // auto-selects it once the engine reports the grown track list.
    var addonSubtitles by remember(playbackSessionKey) { mutableStateOf<List<AddonSubtitle>>(emptyList()) }
    val mountedAddonSubs = remember(playbackSessionKey) { mutableSetOf<String>() }
    var pendingSubSelectAbove by remember(playbackSessionKey) { mutableStateOf<Int?>(null) }
    LaunchedEffect(playbackSessionKey) {
        if (currentPlayable.isTrailer) return@LaunchedEffect
        val ref = currentPlayable.mediaRef ?: return@LaunchedEffect
        val (type, videoId) = SubtitleAddonService.queryFor(ref) ?: return@LaunchedEffect
        val repo = (context.applicationContext as? VortXApplication)?.catalogRepository ?: return@LaunchedEffect
        val sources = SubtitleAddonService.installedSources(repo.installedAddons().getOrNull().orEmpty())
        if (sources.isEmpty()) return@LaunchedEffect
        val store = TrackPreferencesStore(context, PerformanceMode.isConstrainedDevice(context))
        addonSubtitles = TrackSelector.keepingPreferredSubtitleLanguages(
            items = SubtitleAddonService.fetch(sources, type, videoId),
            enabled = store.subtitlesOnlyPreferred,
            preferredLanguages = store.current.subtitleLanguages,
            language = AddonSubtitle::lang,
        )
    }
    // A picked add-on subtitle has mounted when the engine's subtitle list grows past its pre-mount
    // count; select the newly appended track (mpv appends on `sub-add`, the ExoPlayer rebuild
    // appends the side-loaded config last). Idempotent on mpv, whose `sub-add` default flag already
    // selects the new track.
    LaunchedEffect(playerState.subtitleTracks) {
        val preMountCount = pendingSubSelectAbove ?: return@LaunchedEffect
        val tracks = latestState.subtitleTracks
        if (tracks.size > preMountCount) {
            tracks.lastOrNull()?.let { engine.selectSubtitleTrack(it.id) }
            pendingSubSelectAbove = null
        }
    }

    // Preference-driven auto track selection (the Android port of Apple TrackSelector): once the engine
    // reports its track list, pick the audio + subtitle track per the persisted TrackPreferences, exactly
    // ONCE per load. This closes the "manual select only" parity gap. A nil audio pick leaves the engine's
    // own default; a -1 subtitle pick means "off". Runs after the engine's own default selection, so it
    // overrides toward the user's language chain (e.g. a Turkish-only preference beats a French dub, #76).
    val trackPreferences = remember(playbackSessionKey) {
        TrackPreferencesStore(context, PerformanceMode.isConstrainedDevice(context)).current
    }
    // Read once per load alongside the preferences: when ON, the auto audio pick follows the subtitle chain
    // (Apple `matchAudioSub`). Separate from [trackPreferences] because it is not part of the value struct.
    val matchAudioSub = remember(playbackSessionKey) {
        TrackPreferencesStore(context, PerformanceMode.isConstrainedDevice(context)).matchAudioSub
    }
    var autoSelectDone by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(playbackSessionKey, playerState.audioTracks, playerState.subtitleTracks) {
        if (autoSelectDone) return@LaunchedEffect
        val audioTracks = latestState.audioTracks
        val subtitleTracks = latestState.subtitleTracks
        if (audioTracks.isEmpty() && subtitleTracks.isEmpty()) return@LaunchedEffect
        val pick = TrackSelector.select(audioTracks, subtitleTracks, trackPreferences, matchAudioSub)
        // Fidelity refinement: among same-language audio tracks, honour the channel layout the active
        // output route can render, the tie-break Apple's picker cannot make (TrackSelector.swift documents
        // MPVTrack carries no channel counts). Fail-soft: unknown channels leave the language pick as-is.
        val audioId = com.vortx.android.player.audio.AudioTrackFidelity.refine(
            audioTracks,
            pick.audioId,
            trackPreferences.rejectTerms,
            com.vortx.android.player.audio.AudioRoute.current(context),
        )
        audioId?.let { engine.selectAudioTrack(it) }
        val subId = pick.subtitleId
        if (subId != null && subId >= 0) engine.selectSubtitleTrack(subId) else engine.selectSubtitleTrack(null)
        autoSelectDone = true
    }

    // Apply the persisted subtitle appearance to whichever engine is live (mpv sub-* properties / ExoPlayer
    // SubtitleView style). The mpv engine also applies it pre-init; this covers the ExoPlayer path and any
    // future live Settings change once the player-settings screen lands (Round 6).
    LaunchedEffect(engine) { engine.applySubtitleStyle() }

    // Skip segments (intro / recap / credits) for this title, fetched ONCE the engine reports a real
    // duration (the crowd providers are keyed + clamped by runtime). Fail-soft: no [Playable.mediaRef]
    // (an unmappable id / the offline preview), a title with no crowd data, or a flaky edge simply leaves
    // an empty list and no skip button ever shows. Mirrors the Apple player's skip gate, which loads
    // SkipTimestampService.candidates once it has the imdb id + duration and resolves them through
    // SegmentResolver. This is the READ side; the in-player submit editor (SkipDBClient) is a later round.
    var skipSegments by remember(playbackSessionKey) { mutableStateOf<List<SkipSegment>>(emptyList()) }
    // TV skip-pill dismissal (Back-to-dismiss while the chrome is hidden): the `start` of the segment the
    // viewer waved off, so its pill stays hidden until the next segment. Reset per playback session and
    // cleared on a skip. Only ever set on TV (isTvPlayer); the phone leaves it null so the pill is unchanged.
    var dismissedSkipStart by remember(playbackSessionKey) { mutableStateOf<Double?>(null) }
    LaunchedEffect(playbackSessionKey, playerState.durationMs > 0L) {
        val ref = currentPlayable.mediaRef
        val imdb = ref?.imdb
        val durationMs = latestState.durationMs
        if (imdb.isNullOrEmpty() || durationMs <= 0L) return@LaunchedEffect
        SkipTimestampService.init(context.applicationContext)
        val durationSec = durationMs / 1000.0
        val candidates = SkipTimestampService.candidates(
            metaId = imdb,
            season = ref.season,
            episode = ref.episode,
            durationSeconds = durationSec,
        )
        skipSegments = SegmentResolver.resolve(candidates, durationSec)
    }

    // Keep the once-per-segment memory across same-episode source failover. A URL is source identity, not
    // media identity; two failed sources for one episode must not cause the same intro to auto-skip twice.
    val autoSkipIdentity = autoSkipMediaIdentity(currentPlayable)
    val autoSkipEnabled = remember(autoSkipIdentity) {
        PlaybackBehaviorSettings.autoSkip(context.applicationContext)
    }
    val autoSkippedStarts = remember(autoSkipIdentity) { mutableSetOf<Double>() }
    LaunchedEffect(autoSkipEnabled, skipSegments, playerState.positionMs / 1000L) {
        if (!autoSkipEnabled) return@LaunchedEffect
        val target = AutoSkipPolicy.target(skipSegments, latestState.positionMs, autoSkippedStarts)
            ?: return@LaunchedEffect
        autoSkippedStarts += target.start
        engine.seekTo((target.end * 1000).toLong())
    }

    // Community trickplay (shared scrub previews). Three seams, all fail-soft, all keyed per title:
    //   1. KEY + FETCH  -- below, once the engine reports a real duration.
    //   2. CAPTURE      -- the wall-clock driver further down.
    //   3. SERVE        -- [previewAt] handed to the chrome's scrubber.
    // The session owns its own scope (it must outlive this composition to flush on exit), so it is only
    // remembered here, never scoped to the composition.
    val trickplay = remember(playbackSessionKey) { TrickplaySession(context) }

    // KEY + FETCH. Gated on a real reported duration because the content key is
    // sha1(imdb:season:episode:durationBucket) -- keying on 0 would compute the WRONG key and index a
    // different pool row. This is the same `durationMs > 0` gate the skip-segment fetch above uses, so it
    // is the established contract for "the engine now knows the title's real length".
    //
    // [TrickplaySession.configure] is idempotent and does the tmdb->imdb resolve itself: a hub/TMDB-catalog
    // play arrives with mediaRef.imdb == null and only a numeric tmdb id, and a tt-only content key would
    // silently drop it (the known past root cause of an account that contributed nothing from any device).
    LaunchedEffect(playbackSessionKey, playerState.durationMs > 0L) {
        val durationMs = latestState.durationMs
        // A junk-length file must never key (or feed) the SHARED community pool: its duration bucket
        // is the wrong file's, not the episode's. Same never-poison rule as the progress writes.
        if (durationMs <= 0L || isJunkDuration(durationMs, currentPlayable)) return@LaunchedEffect
        trickplay.configure(currentPlayable.mediaRef, durationMs / 1000.0)
    }

    // CAPTURE. A wall-clock driver, deliberately NOT a position-delta driver: Apple runs both (a timePos
    // handler plus a timer) because a 4K/HDR debrid stream can coalesce or never emit position ticks, and
    // the timer is the one that always fires. Android's [PlayerState] republishes position ~1s on both
    // engines, but the timer is still the robust choice and needs no second code path.
    //
    // Gates mirror Apple's `maybeCaptureLocalTrickplay`: never grab while paused or buffering (a stalled
    // frame is a duplicate at best, an unrendered black frame at worst), and never before a real duration
    // (the session is not keyed yet, so the frame would be buffered against no title and thrown away).
    // A null return is the normal, expected outcome on the ExoPlayer engine, which cannot read back a
    // SurfaceView without breaking Dolby Vision -- see [PlayerEngine.captureFrameJpeg].
    LaunchedEffect(engine, playbackSessionKey) {
        while (true) {
            delay((TrickplaySession.CAPTURE_INTERVAL_S * 1000).toLong())
            val s = latestState
            // The runtimeMismatch gate keeps a condemned file's frames out of the shared pool (the
            // configure above already refused to key the session on a junk duration).
            // The settle check keeps an unrendered mid-switch frame out of the shared timeline.
            if (s.isPaused || s.isBuffering || s.durationMs <= 0L || runtimeMismatch ||
                afrHolder.get()?.isSettling() == true
            ) continue
            val jpeg = engine.captureFrameJpeg(TRICKPLAY_TILE_MAX_WIDTH) ?: continue
            // Read the source height HERE, while the engine is demonstrably alive and rendering, and bank
            // it with the frame. Doing it at teardown instead would mean a JNI property read against an
            // engine that may already be released, which is a native crash, not a catchable one.
            trickplay.recordFrame(jpeg, s.positionMs / 1000.0, videoHeightOf(engine))
        }
    }

    // TEARDOWN FLUSH. The session pushes progressively during playback (Apple learned that a teardown may
    // never fire: the title ends, the device sleeps, auto-advance takes over, or the process is killed), so
    // this is the backstop that sends the final, fullest set. It survives this composition because the
    // session owns a SupervisorJob scope rather than a remembered one, and it deliberately touches only
    // session state, never the engine that is being released alongside it.
    DisposableEffect(playbackSessionKey) {
        onDispose { trickplay.finishAndFlush() }
    }

    // When playback reaches its natural end, hand the ended signal to the host: the phone shell's Up
    // Next auto-advance for a series episode with a successor, or a plain return to the detail page
    // otherwise ([onEnded] defaults to [onBack]). GATED on ended-and-not-errored: a failed source must
    // surface the error overlay, never fire the next-episode auto-advance (the audit's wrong-auto-
    // advance defect). The mpv engine now keeps hasEnded/hasError mutually exclusive at the source;
    // this is the belt-and-suspenders at the dispatch seam, and it also covers the watchdog's verdict.
    //
    // EOF BACKSTOP (the runtime-mismatch second gate): only a GENUINE completion -- the playhead got
    // through most of the expected runtime -- may reach [onEnded]. An EOF whose playhead sits
    // implausibly short of the expected runtime means the FILE was wrong even though its duration
    // header looked sane (or was never judged), so it is converted into the runtime-mismatch verdict
    // (-> the error surface + the host's retry ladder) instead of an ended signal. This is what makes
    // "play a 10-second junk file to its end" structurally unable to mark an episode watched or
    // auto-advance, whichever engine reported the EOF.
    LaunchedEffect(playerState.hasEnded) {
        val s = latestState
        if (!playerState.hasEnded || s.hasError || stallError || runtimeMismatch) return@LaunchedEffect
        // A userForcedSource play skips the conversion (the viewer chose this exact file off the
        // manual fallback; its end is their end) -- but its progress writes were still junk-gated, so
        // even a forced junk file reaches here UNWATCHED and the advance is the viewer's own doing.
        if (!currentPlayable.userForcedSource && isJunkEof(s.positionMs, s.durationMs, currentPlayable)) {
            runtimeMismatch = true
            return@LaunchedEffect
        }
        // Sleep timer set to "End of episode": this one finished, so STOP here (leave the player) rather
        // than auto-advancing to the next episode. Mirrors the Apple sleepAtEpisodeEnd branch.
        if (sleepAtEpisodeEnd) {
            sleepAtEpisodeEnd = false
            currentOnBack()
            return@LaunchedEffect
        }
        // A LOCAL session's end is a plain exit, never [currentOnEnded]: the host's ended handler asks
        // its detail ViewModel for the next episode, and for a download play that ViewModel can belong
        // to an EARLIER streamed title -- finishing downloaded B must never offer or auto-advance into
        // A's successor (AND-DL-01). Exiting matches the TV shell, whose player has always closed on
        // end; a future legitimate local Up Next needs an identity-carrying callback of its own.
        if (isLocalSession) {
            currentOnBack()
            return@LaunchedEffect
        }
        currentOnEnded()
    }

    // Fail-soft watchdog: if the mpv engine flagged a surface-attach failure, rebuild on ExoPlayer. Only
    // the mpv engine exposes this signal; the check is a safe no-op for ExoPlayer.
    LaunchedEffect(engine) {
        val failedFlag = mpvSurfaceFailed(engine)
        if (failedFlag) forceExoPlayer = true
    }

    // Periodic progress writeback while playing, so Continue Watching updates live. The engine's state
    // position advances ~1s on both engines (mpv's time-pos observer, ExoPlayer's position ticker), so a
    // throttled read here is accurate; the host debounces the engine dispatch.
    //
    // NEVER-POISON GATE: a junk-length file must not attribute progress to the real episode -- a tick
    // of (pos~=10s, dur~=10s) reads as a NEAR-END ratio and the repo's end-of-session write would mark
    // the episode WATCHED off it. Gated on the [runtimeMismatch] verdict AND the synchronous
    // [isJunkDuration] read of the same snapshot, so even the first tick after the duration lands can
    // never race the verdict state and slip a poisoned ratio through. A genuine mid-play error is NOT
    // gated (a real 30-minute watch that then dies still deserves its resume point).
    LaunchedEffect(engine) {
        while (true) {
            delay(PROGRESS_REPORT_MS)
            val s = latestState
            if (!s.isPaused && s.durationMs > 0L && !runtimeMismatch && !isJunkDuration(s.durationMs, currentPlayable)) {
                currentOnProgress(s.positionMs, s.durationMs)
                // PLR-8: drive the host's next-episode preload with the live position/duration. The host
                // decides (via its policy) when to warm; a movie / trailer / no-successor host no-ops.
                // A LOCAL session never drives it: warming resolves through the host's detail ViewModel,
                // which for a download play can belong to an earlier streamed title (AND-DL-01).
                if (!isLocalSession) currentOnWarmNext(s.positionMs, s.durationMs)
            }
        }
    }

    // Save-on-exit: emit the freshest position when the player leaves composition, so the host's
    // end-of-session write records where the viewer actually stopped. Same never-poison gate as the
    // periodic tick above: a condemned file's final (pos, dur) pair is the exact write that used to
    // mark a 10-second junk file watched, so it is dropped entirely.
    DisposableEffect(engine) {
        onDispose {
            val s = latestState
            if (s.durationMs > 0L && !runtimeMismatch && !isJunkDuration(s.durationMs, currentPlayable)) {
                currentOnProgress(s.positionMs, s.durationMs)
            }
        }
    }

    // External progress sync (Trakt / SIMKL). Drives scrobble at the play / pause / stop transitions off
    // the engine's live [PlayerState], through [ScrobbleService] which fans out to every connected
    // provider (Trakt live scrobble; SIMKL watched-on-finish). A [Playable] with no [Playable.mediaRef]
    // (the offline preview, an unmappable id) never scrobbles. [ScrobbleService]'s ops are fire-and-forget
    // on its own scope, so nothing here blocks playback and the stop still completes after this leaves
    // composition. See com.vortx.android.integrations.ScrobbleService.
    val scrobbleRef = currentPlayable.mediaRef
    // Latch the started/paused transitions so a play sends exactly one `start`, a resume sends one `start`,
    // and a pause sends one `pause`, rather than a scrobble on every recomposition.
    var scrobbleStarted by remember(playbackSessionKey) { mutableStateOf(false) }
    var scrobblePauseSent by remember(playbackSessionKey) { mutableStateOf(false) }
    LaunchedEffect(playerState.isPaused, playerState.durationMs > 0L, playerState.hasEnded) {
        val ref = scrobbleRef ?: return@LaunchedEffect
        // Never start scrobbling a condemned junk file (the mismatch verdict lands with the duration
        // report, before or alongside the first possible start here).
        if (runtimeMismatch) return@LaunchedEffect
        ScrobbleService.init(context.applicationContext)
        val s = latestState
        if (s.durationMs <= 0L || s.hasEnded || isJunkDuration(s.durationMs, currentPlayable)) return@LaunchedEffect
        val progress = s.positionMs.toDouble() / s.durationMs.toDouble() * 100.0
        if (!s.isPaused) {
            // First play, or a resume: Trakt uses `start` for both.
            ScrobbleService.start(ref, progress)
            scrobbleStarted = true
            scrobblePauseSent = false
        } else if (scrobbleStarted && !scrobblePauseSent) {
            ScrobbleService.pause(ref, progress)
            scrobblePauseSent = true
        }
    }
    DisposableEffect(playbackSessionKey) {
        onDispose {
            val ref = scrobbleRef
            if (ref != null && scrobbleStarted) {
                val s = latestState
                // NEVER-POISON GATE: a junk-length file's EOF ratio is ~100%, which Trakt records as
                // WATCHED (>= 80%) and SIMKL writes to history. A condemned source therefore stops at
                // 0% -- the session still closes cleanly server-side, but records nothing watched.
                val junk = runtimeMismatch || isJunkDuration(s.durationMs, currentPlayable)
                val progress = if (s.durationMs > 0L && !junk) {
                    s.positionMs.toDouble() / s.durationMs.toDouble() * 100.0
                } else {
                    0.0
                }
                // Stop records the watch server-side (Trakt at >= 80%, plus a SIMKL history write).
                ScrobbleService.stop(ref, progress)
            }
        }
    }

    // AudioFocus: pause when another app takes audio (a call, another player) so VortX never talks over
    // it, and resume on gain. Standard AudioManager focus request (minSdk 26 carries AudioFocusRequest).
    // The pause/resume DECISION is [AudioFocusPolicy] (pure, unit-tested): it pauses on every loss
    // class (transient included; ducking film dialog is worse than pausing it) but only ever
    // auto-RESUMES playback the policy itself paused, so a GAIN can no longer un-pause a film the
    // viewer had paused deliberately before the interruption.
    DisposableEffect(engine) {
        val focusPolicy = AudioFocusPolicy()
        val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
            when (focusPolicy.onFocusChange(change, latestState.isPaused)) {
                AudioFocusPolicy.Action.PAUSE -> engine.pause()
                AudioFocusPolicy.Action.RESUME -> engine.play()
                AudioFocusPolicy.Action.NONE -> Unit
            }
        }
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                    .build(),
            )
            .setOnAudioFocusChangeListener(focusListener)
            .build()
        audioManager?.requestAudioFocus(request)
        onDispose { audioManager?.abandonAudioFocusRequest(request) }
    }

    // TV re-reveal path: when the chrome hides, its focusable buttons leave composition and D-pad input
    // would dead-end. Parking focus on the root box lets the next key press land in [onKeyEvent] below,
    // which consumes it and re-shows the controls (Back/Escape excepted, so Back still exits the player).
    val rootFocus = remember { FocusRequester() }
    LaunchedEffect(controlsVisible) {
        if (!controlsVisible) runCatching { rootFocus.requestFocus() }
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .focusRequester(rootFocus)
            .onKeyEvent { event ->
                if (event.type != KeyEventType.KeyDown) return@onKeyEvent false
                // MEDIA transport keys (TV remote play/pause/ffwd/rew, BT keyboards) drive the
                // engine directly, before every other branch: a deliberate hardware transport press
                // is never the accidental touch the lock guards, and a blind press while the chrome
                // is hidden should ACT, not merely reveal. Consuming here also keeps the window
                // authoritative over the MediaSession for these keys (the session only receives
                // media keys the foreground window did not handle), so D-pad focus handling below
                // and in the chrome is untouched by the session by construction.
                when (event.key) {
                    Key.MediaPlayPause -> {
                        showControls()
                        markMpvUserPausedIntent(engine, !latestState.isPaused)
                        engine.togglePause()
                        return@onKeyEvent true
                    }
                    Key.MediaPlay -> {
                        showControls()
                        markMpvUserPausedIntent(engine, false)
                        engine.play()
                        return@onKeyEvent true
                    }
                    Key.MediaPause -> {
                        showControls()
                        markMpvUserPausedIntent(engine, true)
                        engine.pause()
                        return@onKeyEvent true
                    }
                    Key.MediaFastForward -> {
                        showControls()
                        engine.seekBy(seekStepMs)
                        return@onKeyEvent true
                    }
                    Key.MediaRewind -> {
                        showControls()
                        engine.seekBy(-seekStepMs)
                        return@onKeyEvent true
                    }
                    else -> Unit
                }
                if (controlsLocked) {
                    // Locked: swallow everything except Back/Escape (leaving the player must always
                    // work). OK/Enter UNLOCKS, so a D-pad-only device (TV, or a phone with a remote)
                    // can always get out of the lock without a touchscreen; any other key just
                    // surfaces the unlock affordance so the press is not a dead end.
                    if (event.key == Key.Back || event.key == Key.Escape) return@onKeyEvent false
                    if (event.key == Key.Enter || event.key == Key.NumPadEnter || event.key == Key.DirectionCenter) {
                        controlsLocked = false
                        unlockHintVisible = false
                        showControls()
                        return@onKeyEvent true
                    }
                    revealUnlockHint()
                    return@onKeyEvent true
                }
                if (!controlsVisible) {
                    // TV hidden-chrome SKIP PILL reachability: while a resolved skip segment sits under the
                    // playhead and its pill has not been waved off, Select seeks past it and Back dismisses the
                    // pill (rather than leaving the player), so the couch reaches the skip without raising the
                    // whole transport bar. The phone host passes isTvPlayer=false, so this is inert there and
                    // Back keeps its "leave the player" meaning.
                    val posSec = latestState.positionMs / 1000.0
                    val activeSkip = if (isTvPlayer) {
                        skipSegments.filter { posSec >= it.start && posSec < it.end }.minByOrNull { it.start }
                    } else {
                        null
                    }
                    if (activeSkip != null && activeSkip.start != dismissedSkipStart) {
                        when (event.key) {
                            Key.Back, Key.Escape -> {
                                dismissedSkipStart = activeSkip.start
                                return@onKeyEvent true
                            }
                            Key.Enter, Key.NumPadEnter, Key.DirectionCenter -> {
                                engine.seekTo((activeSkip.end * 1000).toLong())
                                dismissedSkipStart = null
                                return@onKeyEvent true
                            }
                            else -> Unit
                        }
                    }
                    // Back must keep meaning "leave the player", never be swallowed into a reveal.
                    if (event.key == Key.Back || event.key == Key.Escape) return@onKeyEvent false
                    // HIDDEN-CHROME D-PAD NUDGE: Left/Right does a small seek and shows a floating time pill
                    // WITHOUT raising the whole transport bar, so a quick correction stays unobtrusive.
                    // Mirrors Apple's `hiddenSeek`.
                    if (event.key == Key.DirectionLeft || event.key == Key.DirectionRight) {
                        val forward = event.key == Key.DirectionRight
                        val delta = if (forward) seekStepMs else -seekStepMs
                        engine.seekBy(delta)
                        // The pill shows the predicted target; the engine clamps the real seek to the file.
                        seekNudgeTargetMs = (latestState.positionMs + delta).coerceAtLeast(0L)
                        seekNudgeTick++
                        return@onKeyEvent true
                    }
                    showControls()
                    true
                } else {
                    // A key travelling through while the chrome is up (D-pad focus moves between the
                    // buttons bubble up here unconsumed) counts as interaction: re-arm the hide timer.
                    controlsInteractionTick++
                    false
                }
            }
            .focusable(),
    ) {
        engine.VideoSurface(modifier = Modifier.fillMaxSize(), emberArgb = emberAccent.toArgb(), scaleMode = scaleMode)

        // Tap layer: single tap toggles the chrome; double-tap seeks (right half = +10s, left half =
        // -10s, the standard mobile-player gesture) and re-shows the chrome so the seek is visible.
        // Layered OVER the video surface and UNDER the chrome, so the chrome's own controls keep their
        // taps (they hit-test first) and only bare-video taps land here. Keyed on the engine so a
        // mid-session ExoPlayer fallback rebinds the gesture to the live engine. A PiP window
        // receives no app touch input, so both detectors stand down while [pip.isInPip].
        //
        // The SECOND pointerInput is the drag-gesture surface (PlayerGestures.kt): left-half
        // vertical = window brightness, right-half vertical = media volume, horizontal = seek with a
        // live target HUD, committed on release. The two detectors run in parallel on this one Box;
        // the drag consuming its position changes is what makes the tap detector give up on drags,
        // so a brightness swipe never also toggles the chrome. Drags are withheld while locked (the
        // lock's whole point), in PiP, and under the error overlay (seeking a dead source from a
        // half-visible gesture would fight the retry ladder).
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(engine, controlsLocked, pip.isInPip, stillWatchingPrompt) {
                    // The Still Watching modal owns the surface while it is up: no bare-video tap should
                    // toggle the chrome or seek underneath it.
                    if (pip.isInPip || stillWatchingPrompt) return@pointerInput
                    if (controlsLocked) {
                        // Locked: taps only reveal the unlock affordance; the double-tap seek is
                        // deliberately absent so no gesture can move playback.
                        detectTapGestures(onTap = { revealUnlockHint() })
                    } else {
                        detectTapGestures(
                            onTap = {
                                if (controlsVisible) controlsVisible = false else showControls()
                            },
                            onDoubleTap = { offset ->
                                val forward = offset.x >= size.width / 2
                                // The double-tap step follows the viewer's Skip step (Apple `stremiox.seekStep`).
                                engine.seekBy(if (forward) seekStepMs else -seekStepMs)
                                showControls()
                            },
                        )
                    }
                }
                .pointerInput(engine, controlsLocked, pip.isInPip, effectiveError, stillWatchingPrompt) {
                    if (controlsLocked || pip.isInPip || effectiveError || stillWatchingPrompt) return@pointerInput
                    detectPlayerDragGestures(
                        currentPositionMs = { latestState.positionMs },
                        currentDurationMs = { latestState.durationMs },
                        currentBrightness = { windowBrightnessFraction(hostActivity) },
                        // RIGHT-HALF SWIPE now drives the APP (engine) volume, not the system STREAM_MUSIC
                        // level, so the in-player slider, the mute button and the swipe all move one value
                        // (Apple `stremiox.playerVolume`). setPlayerVolume persists + un-mutes on a raise.
                        currentVolumeFraction = { (playerVolume / 100.0).toFloat() },
                        onBrightness = { setWindowBrightnessFraction(hostActivity, it) },
                        onVolumeFraction = { setPlayerVolume((it * 100.0)) },
                        onSeekCommit = { target ->
                            showControls()
                            engine.seekTo(target)
                        },
                        onHud = { gestureHud = it },
                    )
                },
        )

        PlayerChrome(
            playable = currentPlayable,
            playbackSessionRevision = sourceSwitchState.revision,
            // The watchdog's stall verdict and the runtime-mismatch verdict both ride the same
            // hasError the engines publish, so the chrome has exactly one error surface (the overlay
            // + "Choose another source" retry path). A mismatch additionally clears hasEnded: the
            // junk file may genuinely have EOF'd, but presenting "ended" for a wrong file would be
            // the exact lie this fix removes.
            state = when {
                runtimeMismatch -> playerState.copy(hasError = true, hasEnded = false)
                stallError -> playerState.copy(hasError = true)
                else -> playerState
            },
            // DV BADGE HONESTY (Apple: the badge is earned only by the true-DV lane): show DOLBY VISION only
            // when this is a DV source, the live engine is the DV lane (ExoPlayer), AND the panel presents
            // DV. On the libmpv lane a DV source is tone-mapped to HDR10, so no DV badge there -- the
            // Dynamic range row below tells the honest truth instead.
            dolbyVisionAvailable = currentPlayable.isDolbyVision &&
                engine is ExoPlayerEngine &&
                displaySupportsDolbyVision(context),
            // The honest dynamic-range line for the Playback Info sheet: true DV on the DV lane, else the
            // "HDR10 tone-mapped from Dolby Vision" truth for a DV source on the libmpv lane. Null (omit the
            // row) for a non-DV source, whose codec/HDR is already shown by the engine stats.
            dynamicRange = when {
                !currentPlayable.isDolbyVision -> null
                engine is ExoPlayerEngine && displaySupportsDolbyVision(context) -> "Dolby Vision"
                else -> "HDR10 (tone-mapped from Dolby Vision)"
            },
            seekStepMs = seekStepMs,
            seekStepSeconds = seekStepSeconds,
            playerVolume = playerVolume,
            playerMuted = playerMuted,
            onSetVolume = { setPlayerVolume(it) },
            onToggleMute = { togglePlayerMute() },
            emberAccent = emberAccent,
            speed = speed,
            scaleMode = scaleMode,
            chapters = chapters,
            skipBands = skipSegments.map { seg ->
                com.vortx.android.player.extras.SkipBand(seg.start, seg.end, skipBandColor(seg.kind))
            },
            subtitleDelayAvailable = engine.subtitleDelayAvailable,
            subtitleDelaySeconds = subtitleDelaySeconds,
            onAdjustSubtitleDelay = { delta ->
                showControls()
                subtitleDelaySeconds = adjustedPlayerDelay(subtitleDelaySeconds, delta)
                engine.setSubtitleDelay(subtitleDelaySeconds)
                SubtitleOffsetMemory.save(context, subtitleDelaySeconds, subtitleContentKey)
            },
            subtitleStyle = subtitleStyle,
            onChangeSubtitleStyle = { next ->
                showControls()
                SubtitleStyle.save(context, next)
                subtitleStyle = SubtitleStyle.current(context)
                engine.applySubtitleStyle()
            },
            audioDelayAvailable = engine.audioDelayAvailable,
            audioDelaySeconds = audioDelaySeconds,
            audioOutputModeAvailable = engine.audioOutputModeAvailable,
            audioOutputMode = audioOutputMode,
            onAdjustAudioDelay = { delta ->
                showControls()
                audioDelaySeconds = adjustedPlayerDelay(audioDelaySeconds, delta)
                engine.setAudioDelay(audioDelaySeconds)
            },
            onSelectAudioOutputMode = { mode ->
                showControls()
                if (engine.audioOutputModeAvailable) {
                    audioOutputMode = mode
                    AudioOutputMode.setCurrent(context, mode)
                    engine.setAudioOutputMode(mode)
                }
            },
            // Also withheld in PiP: the tiny window gets video only (the system draws the PiP
            // controls; ours would be unreachable dead pixels under them).
            controlsVisible = controlsVisible && !controlsLocked && !pip.isInPip,
            // Continuous interactions the chrome owns internally (scrubber drags, sheet opens) re-arm
            // the auto-hide timer through this seam; the discrete actions below re-arm via [showControls].
            onInteraction = { showControls() },
            onBack = currentOnBack,
            onTogglePause = {
                showControls()
                markMpvUserPausedIntent(engine, !latestState.isPaused)
                engine.togglePause()
            },
            onSeek = { showControls(); engine.seekTo(it) },
            onSeekBy = { showControls(); engine.seekBy(it) },
            onSelectAudio = { showControls(); engine.selectAudioTrack(it) },
            onSelectSubtitle = { showControls(); engine.selectSubtitleTrack(it) },
            onSetSpeed = { newSpeed ->
                showControls()
                speed = newSpeed
                engine.setPlaybackSpeed(newSpeed)
            },
            onSelectScaleMode = { mode ->
                showControls()
                scaleMode = mode
                // Persist under Apple's key so the pick survives this title and rides the cross-device blob.
                com.vortx.android.player.extras.AspectRatioSetting.setCurrent(context, mode)
            },
            onErrorRetry = currentOnError,
            sourceOptions = if (currentOnSwitchSource != null) sourceOptions else emptyList(),
            qualityOptions = if (currentOnSwitchSource != null) qualityOptions else emptyList(),
            episodeOptions = if (currentOnSwitchEpisode != null) episodeOptions else emptyList(),
            currentSource = sourceSwitchState.currentSource,
            sourceSwitching = sourceSwitchState.isSwitching,
            sourceSwitchError = sourceSwitchState.errorMessage,
            onSwitchSource = { source ->
                val resolver = currentOnSwitchSource
                if (
                    resolver != null &&
                    !sourceSwitchState.isSwitching &&
                    !playerSourceIsCurrent(source, sourceSwitchState.currentSource)
                ) {
                    sourceSwitchCoordinator.beginRequest(outerPlaybackSessionId)?.let { authority ->
                        sourceSwitchState = beginPlayerSourceSwitch(
                            state = sourceSwitchState,
                            source = source,
                            authority = authority,
                        )
                    }
                }
            },
            onSwitchEpisode = { episode ->
                val resolver = currentOnSwitchEpisode
                val currentRef = sourceSwitchState.playable.mediaRef
                if (
                    resolver != null &&
                    !sourceSwitchState.isSwitching &&
                    !(currentRef?.isSeries == true &&
                        currentRef.season == episode.season &&
                        currentRef.episode == episode.episode)
                ) {
                    sourceSwitchCoordinator.beginRequest(outerPlaybackSessionId)?.let { authority ->
                        sourceSwitchState = beginPlayerEpisodeSwitch(
                            state = sourceSwitchState,
                            episode = episode,
                            authority = authority,
                        )
                    }
                }
            },
            // The explicit PiP entry (user action); null on devices/hosts that cannot PiP, which
            // hides the control entirely. Home-press entry rides auto-enter / onUserLeaveHint.
            onEnterPip = if (pip.supported) {
                { pip.enter() }
            } else {
                null
            },
            // Google Cast button (the CAST lane). Supplied ONLY when the Cast framework is available AND the
            // current stream is castable (a direct/HLS/debrid URL, never a loopback torrent); the button
            // itself further self-hides when no receivers are on the network. Opening it shows the device
            // chooser. Withheld while locked or in PiP (the cluster is unreachable then anyway).
            castButton = if (castManager.isEnabled && streamCastable) {
                {
                    CastButton(
                        state = castState,
                        emberAccent = emberAccent,
                        onClick = { showControls(); castChooserOpen = true },
                    )
                }
            } else {
                null
            },
            onLock = {
                controlsLocked = true
                controlsVisible = false
                // Show the unlock pill once on engage so the viewer learns where unlock lives.
                revealUnlockHint()
            },
            addonSubtitles = addonSubtitles,
            onSelectAddonSubtitle = { sub ->
                showControls()
                // Mount once per URL: a re-pick of an already-mounted subtitle would only duplicate
                // the track (it is selectable from the embedded list above once mounted).
                if (mountedAddonSubs.add(sub.url)) {
                    pendingSubSelectAbove = latestState.subtitleTracks.size
                    engine.addExternalSubtitle(sub.url)
                }
            },
            // Secondary (dual) subtitles: mpv-only; the ids are re-read from the live engine on each
            // recomposition so the checkmarks reflect the current secondary-sid / sid after a pick.
            secondarySubtitleAvailable = engine.secondarySubtitleAvailable,
            primarySubtitleId = engine.primarySubtitleId,
            secondarySubtitleId = engine.secondarySubtitleId,
            onSelectSecondarySubtitle = { id ->
                showControls()
                engine.setSecondarySubtitleTrack(id)
            },
            // Sleep timer. End-of-episode is offered only for a series episode (it stops the auto-advance).
            sleepSelectionMinutes = sleepMinutes,
            sleepAtEpisodeEnd = sleepAtEpisodeEnd,
            sleepEndOfEpisodeAvailable = currentPlayable.mediaRef?.isSeries == true,
            onSetSleepTimer = { minutes, atEnd ->
                showControls()
                sleepMinutes = minutes
                sleepAtEpisodeEnd = atEnd
            },
            // In-player engine switch. Hidden for torrents / trailers where the switch is not valid; the
            // live engine name shows which player is active, and picking a preference rebuilds at position.
            engineSwitchAvailable = !currentPlayable.isTorrent && !currentPlayable.isTrailer,
            enginePreference = enginePreference,
            liveEngineLabel = if (engine is ExoPlayerEngine) "Dolby Vision Player" else "VortX Player",
            onSelectEnginePreference = { pref ->
                showControls()
                if (pref != enginePreference) {
                    engineSwitchResumeMs[0] = latestState.positionMs.coerceAtLeast(0L)
                    enginePreference = pref
                }
            },
            // Playback Info: read the live engine stats on each call so the overlay refreshes while open.
            playbackInfo = { engine.playbackStats() },
            // Hardware/software decode (mpv-only). Host-tracked so the checkmark is reactive.
            hardwareDecodingAvailable = engine.hardwareDecodingAvailable,
            hardwareDecoding = hardwareDecoding,
            onSetHardwareDecoding = { hw ->
                showControls()
                hardwareDecoding = hw
                engine.setHardwareDecoding(hw)
            },
            // HDR tone-map (mpv-only). The chrome persists the mode; the host re-applies it to the live engine.
            hdrToneMapAvailable = engine.hdrToneMapAvailable,
            onApplyHdrToneMap = { engine.applyHdrToneMap() },
            // Skip-time editor: offered only for a submittable title (an IMDb id, not live), on either engine.
            onSubmitSkipTime = if (
                com.vortx.android.player.extras.SkipEditPolicy.canEdit(
                    isLiveContent = currentPlayable.isLive,
                    contentId = currentPlayable.mediaRef?.imdb ?: "",
                )
            ) {
                { showSkipEditor = true }
            } else {
                null
            },
            // SERVE: the community scrub preview. Synchronous by contract -- the chrome calls this for
            // every drag frame, so it only ever crops an already-downloaded sprite in memory. Returns null
            // until (or unless) this title has a community sheet, and the scrubber then simply shows no
            // thumbnail, exactly as it does today.
            scrubPreview = trickplay::previewAt,
            // TV-only chrome opt-ins (both default off on the phone host, leaving its chrome unchanged).
            shareLink = shareLink,
            isTvPlayer = isTvPlayer,
            modifier = Modifier.fillMaxSize(),
        )

        // The Skip Intro / Skip Recap / Skip Credits affordance, drawn OVER the chrome (declared last) at
        // the bottom-right, clear of the transport bar. Shows only while the playhead sits inside a
        // resolved segment; a tap seeks to the segment end. Engine-agnostic (drives the same [seekTo] the
        // scrubber does), so it works identically on libmpv and ExoPlayer.
        // While locked, the skip affordance is withheld too: it is a tappable seek, exactly the class
        // of accidental input the lock exists to prevent. Withheld in PiP for the same reason the
        // chrome is: nothing in the small window is tappable by the app.
        if (!controlsLocked && !pip.isInPip) {
            SkipButton(
                segments = skipSegments,
                positionMs = playerState.positionMs,
                emberAccent = emberAccent,
                onSkip = engine::seekTo,
                // TV Back-to-dismiss hides this segment's pill; null on phone leaves it always visible.
                dismissedStart = dismissedSkipStart,
            )
        }

        // The live gesture HUD (seek target / brightness / volume), centered over everything the
        // drag concerns. Rendered only while a drag is in flight; [gestureHud] is cleared on
        // release/cancel and on entering PiP.
        PlayerGestureHudOverlay(hud = gestureHud, emberAccent = emberAccent)

        // The hidden-chrome D-pad seek pill: a small floating time chip at top-centre showing the jump
        // target, without raising the whole transport bar. Withheld in PiP (video-only).
        seekNudgeTargetMs?.takeIf { !pip.isInPip }?.let { target ->
            Box(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 24.dp)
                    .vortxGlassProminent(shape = RoundedCornerShape(10.dp), tint = emberAccent)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Text(
                    text = if (playerState.durationMs > 0L) {
                        "${formatTime(target)} / ${formatTime(playerState.durationMs)}"
                    } else {
                        formatTime(target)
                    },
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                )
            }
        }

        // STILL WATCHING modal: pauses playback and asks after a long idle stretch or a binge boundary.
        // Drawn near-last so it sits above the chrome; the tap/drag layers stand down while it is up.
        // Withheld in PiP (the tiny window is video-only).
        if (stillWatchingPrompt && !pip.isInPip) {
            StillWatchingOverlay(
                emberAccent = emberAccent,
                onContinue = {
                    stillWatchingPrompt = false
                    idleDeadline[0] = SystemClock.elapsedRealtime() + StillWatchingSettings.IDLE_TIMEOUT_MS
                    if (latestState.isPaused) runCatching { engine.play() }
                    showControls()
                },
                onStop = {
                    stillWatchingPrompt = false
                    currentOnBack()
                },
            )
        }

        // The lock's single interactive surface: a small glass pill, revealed by any tap/key while
        // locked and auto-hidden again. Drawn LAST so it sits above the tap layer and is the one
        // thing a finger can actually hit.
        if (controlsLocked && unlockHintVisible && !pip.isInPip) {
            Row(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 24.dp)
                    .vortxGlassProminent(shape = RoundedCornerShape(10.dp), tint = emberAccent)
                    .clickable {
                        controlsLocked = false
                        unlockHintVisible = false
                        showControls()
                    }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    imageVector = Icons.Filled.Lock,
                    contentDescription = "Unlock player controls",
                    tint = Color.White,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = "Tap to unlock",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                )
            }
        }

        // GOOGLE CAST overlay + device chooser (the CAST lane), drawn LAST so they sit above the chrome.
        // The chooser is a dialog the cast button opens. The overlay takes over the surface while a receiver
        // is connected (the local video is paused underneath), naming the device and hosting the cast
        // transport (play/pause, +/-10s, seek, stop). Withheld in PiP, where the tiny window is video-only.
        if (castManager.isEnabled) {
            if (castChooserOpen) {
                CastRouteChooserSheet(onDismiss = { castChooserOpen = false })
            }
            if (castState.isConnected && !pip.isInPip) {
                CastOverlay(
                    state = castState,
                    emberAccent = emberAccent,
                    onBack = currentOnBack,
                    onTogglePlay = { castManager.togglePause() },
                    onSeekBy = { castManager.seekBy(it) },
                    onSeekTo = { castManager.seekTo(it) },
                    onStop = { castManager.stopCasting() },
                )
            }
        }

        // Skip-time editor overlay, drawn above the chrome. Opened from the Player Settings sheet for a
        // submittable title; seeded from the live playhead. Withheld in PiP (the tiny window is video-only).
        val skipImdb = currentPlayable.mediaRef?.imdb
        if (showSkipEditor && skipImdb != null && !pip.isInPip) {
            com.vortx.android.player.extras.SkipSubmitEditor(
                imdbId = skipImdb,
                season = currentPlayable.mediaRef?.season,
                episode = currentPlayable.mediaRef?.episode,
                currentPositionMs = latestState.positionMs,
                durationMs = latestState.durationMs,
                emberAccent = emberAccent,
                onDismiss = { showSkipEditor = false },
            )
        }
    }
}

/// The Skip Intro / Skip Recap / Skip Credits button. Renders only while the playhead is inside one of the
/// resolved [segments]; a tap seeks to that segment's end (ms). Positioned bottom-right, above the
/// transport bar, as ember glass matching the player's other badges. The active-segment recompute is keyed
/// on the whole SECOND (not the raw ms position) so it re-derives at most once per second, not per frame.
@Composable
private fun androidx.compose.foundation.layout.BoxScope.SkipButton(
    segments: List<SkipSegment>,
    positionMs: Long,
    emberAccent: Color,
    onSkip: (Long) -> Unit,
    modifier: Modifier = Modifier,
    // The `start` of a segment the TV viewer dismissed with Back while the chrome was hidden; its pill stays
    // hidden until the next segment. Null (the phone default) never hides the pill.
    dismissedStart: Double? = null,
) {
    if (segments.isEmpty()) return
    val positionSec = positionMs / 1000.0
    // At most one segment applies at a time after the resolver's clamps (intro/recap sit early, credits/
    // preview in the back half); if two overlapped, the earliest-starting wins so "Skip Intro" beats a
    // stray late span.
    val active = remember(segments, positionSec.toLong()) {
        segments.filter { positionSec >= it.start && positionSec < it.end }.minByOrNull { it.start }
    } ?: return
    if (active.start == dismissedStart) return
    // WHY audit 06.5: derive from the pill's existing whole-second tick so phone and TV count down cheaply.
    val remainingSeconds = kotlin.math.ceil(active.end - positionSec).toInt().coerceAtLeast(1)
    val displayLabel = "${active.label} - ${remainingSeconds}s"

    Row(
        modifier = modifier
            .align(Alignment.BottomEnd)
            .padding(end = 20.dp, bottom = 96.dp)
            .vortxGlassProminent(shape = RoundedCornerShape(10.dp), tint = emberAccent)
            .clickable { onSkip((active.end * 1000).toLong()) }
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.SkipNext,
            contentDescription = displayLabel,
            tint = Color.White,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = displayLabel,
            color = Color.White,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
        )
    }
}

/// WHY audit 05.5: pass deliberate transport intent to full-only mpv without coupling the shared source set.
private fun markMpvUserPausedIntent(engine: PlayerEngine, paused: Boolean) {
    runCatching {
        engine.javaClass.methods.firstOrNull {
            it.name == "setUserPausedIntent" && it.parameterCount == 1 &&
                it.parameterTypes[0] == Boolean::class.javaPrimitiveType
        }?.invoke(engine, paused)
    }
}

/// Read the mpv engine's surface-failure flag without the `main` source set depending on the `full`-only
/// `MpvPlayer` type. The `full` flavor's `MpvPlayer` exposes `surfaceFailed`; we consult it reflectively
/// so this `src/main` code compiles in the `play` flavor too (where the type does not exist). Any engine
/// without the flag (ExoPlayer, or `play`) reports false.
private fun mpvSurfaceFailed(engine: PlayerEngine): Boolean {
    return runCatching {
        val prop = engine.javaClass.methods.firstOrNull { it.name == "getSurfaceFailed" && it.parameterCount == 0 }
        (prop?.invoke(engine) as? Boolean) ?: false
    }.getOrDefault(false)
}

/// The source video height tagged onto an uploaded community sheet (the Worker's `src_height` metadata,
/// which lets it prefer a set built from a better source). Derived from the engine-agnostic
/// [PlayerEngine.playbackStats] "Resolution" entry ("1920x1080"), which BOTH engines already publish, so
/// this needs no new engine API. Returns 0 when unknown, which the Worker accepts; Apple passes its
/// `videoHeight` here. Never throws: an absent or unparseable entry is simply 0.
private fun videoHeightOf(engine: PlayerEngine): Int {
    val resolution = runCatching { engine.playbackStats() }.getOrNull()
        ?.firstOrNull { it.first == "Resolution" }?.second ?: return 0
    return resolution.substringAfter('x', "").toIntOrNull() ?: 0
}

/**
 * True when this playable opens a device-LOCAL file (an offline download). Only the download screens
 * produce `file://` playables today; every streamed / torrent / debrid / trailer source resolves to an
 * http(s) or loopback URL. Used to gate the host callbacks that resolve identity from ambient state
 * (auto-next, preload, bad-source ladder) so a local session can never act on a foreign title
 * (audit AND-DL-01).
 */
internal fun isLocalFilePlayback(playable: Playable): Boolean = playable.url.startsWith("file:")

/**
 * Stable media identity for automatic-skip lifecycle state. IMDb plus season/episode survives a source
 * failover for the same title. A series row without a complete episode identity is not safely mappable, so
 * it falls back to the concrete URL rather than sharing skip state across every episode of one show.
 */
internal fun autoSkipMediaIdentity(playable: Playable): String {
    val ref = playable.mediaRef
    val imdb = ref?.imdb?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
    if (imdb != null) {
        if (ref.isSeries) {
            val season = ref.season?.takeIf { it > 0 }
            val episode = ref.episode?.takeIf { it > 0 }
            if (season != null && episode != null) return "imdb:$imdb:s$season:e$episode"
        } else {
            return "imdb:$imdb"
        }
    }
    return "url:${playable.url}"
}

/** Apple-compatible one-decimal delay grid, also canonicalizing negative zero after Reset. */
internal fun adjustedPlayerDelay(current: Double, delta: Double): Double {
    val adjusted = ((current + delta) * 10.0).roundToInt() / 10.0
    return if (adjusted == -0.0) 0.0 else adjusted
}

/// Resolve the hosting [Activity] from a Compose [LocalContext], which may be a [ContextWrapper] chain
/// (theme wrappers, configuration overrides). Null when unhosted (previews/tests), and every caller
/// treats null as "no orientation/insets control", never a crash. Internal (was private): the PiP
/// wiring (PlayerPip.kt) and the session-activity resolve (PlayerMediaSession.kt) walk the same chain.
internal tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}


/// How often watch progress is written back while casting, matching the receiver's ~1s progress cadence
/// closely enough for Continue Watching while staying light. Uses the SAME onProgress path as local
/// playback so casting never bypasses per-profile watch history.
private const val CAST_PROGRESS_WRITEBACK_MS = 5_000L

/// How long the chrome stays up with no interaction while playback is rolling before it auto-hides.
/// 3.5s sits in the standard mobile-player band (3-4s); paused/buffering/error states never hide.
private const val CONTROLS_AUTO_HIDE_MS = 3_500L

/// How long the locked player's "Tap to unlock" pill stays up after each reveal. Shorter than the
/// chrome's auto-hide: while locked the whole point is an undisturbed frame.
private const val UNLOCK_HINT_AUTO_HIDE_MS = 2_500L

/// How long the hidden-chrome D-pad seek pill stays up after each nudge. Brief: it is a quick
/// confirmation of the jump, not persistent chrome.
private const val SEEK_NUDGE_PILL_AUTO_HIDE_MS = 1_200L

/// Chapter metadata can trail the first duration publication by a few demux ticks. Read it only during
/// this bounded startup window so ExoPlayer's empty result and chapterless files never create a poll loop.
private const val CHAPTER_READ_ATTEMPTS = 5
private const val CHAPTER_READ_RETRY_MS = 400L

/// Watchdog sampling cadence: once a second, matching the ~1s position republish of both engines, so a
/// healthy stream is seen advancing on every tick.
private const val WATCHDOG_POLL_MS = 1_000L

/// How long a source may take from load to the FIRST position advance before the watchdog calls it
/// failed. Generous: a cold debrid link or a torrent warm-up legitimately takes many seconds to first
/// data, but half a minute of nothing is a dead source, not a slow one.
private const val WATCHDOG_START_TIMEOUT_MS = 30_000L

/// How long an already-playing stream may hold position (un-paused) before the watchdog calls it
/// stalled. Tighter than the start bound: mid-stream the pipeline is proven, so a long freeze is a
/// dead connection, and the verdict self-clears if the stream recovers.
private const val WATCHDOG_STALL_TIMEOUT_MS = 20_000L

/// Whether the FILE's demuxed duration is implausibly short for the title being played, i.e. the
/// source resolved to the WRONG file (a removed episode's ~10s debrid junk/sample). With a known
/// expected runtime ([Playable.expectedDurationMs], from catalog metadata) the file is junk when it
/// runs under `min(expected/2, expected - 10min)`: half-length catches a sample/clip against any
/// feature runtime, while the 10-minute slack keeps a legitimately shorter cut of a short episode
/// out of the verdict (for anything under ~20 minutes expected, the slack term shrinks the
/// threshold toward zero, so only truly tiny files are condemned). With NO expected runtime the
/// only safe signal is the absolute floor: nothing feature-length is under [JUNK_DURATION_FLOOR_MS].
/// Trailers are exempt (short by design); a non-positive duration is "not demuxed yet", never junk.
/// The scrubber band colour for a skippable segment kind. Cool cyan for the intro, amber for a recap,
/// violet for the credits, and orange for a next-episode preview, so a glance at the bar reads what each
/// coloured stretch is. Kept next to the player because [PlayerChrome]'s scrubber is colour-agnostic.
/// Unwrap the hosting [android.app.Activity] from a Compose [android.content.Context] (which may be a
/// ContextWrapper chain), or null when none is found. Used to drive the window's requested orientation.
private fun activityOf(context: android.content.Context): android.app.Activity? {
    var ctx: android.content.Context = context
    while (ctx is android.content.ContextWrapper) {
        if (ctx is android.app.Activity) return ctx
        ctx = ctx.baseContext
    }
    return null
}

private fun skipBandColor(kind: SkipSegment.Kind): Color = when (kind) {
    SkipSegment.Kind.INTRO -> Color(0xFF3FC7E0)
    SkipSegment.Kind.RECAP -> Color(0xFFE0B23F)
    SkipSegment.Kind.CREDITS -> Color(0xFF9B7BE0)
    SkipSegment.Kind.PREVIEW -> Color(0xFFE0803F)
}

private fun isJunkDuration(fileDurationMs: Long, playable: Playable): Boolean {
    if (playable.isTrailer || fileDurationMs <= 0L) return false
    val expectedMs = playable.expectedDurationMs
    if (expectedMs > 0L) {
        val threshold = minOf(expectedMs / 2, expectedMs - EXPECTED_RUNTIME_SLACK_MS)
        return fileDurationMs < threshold
    }
    return fileDurationMs < JUNK_DURATION_FLOOR_MS
}

/// The EOF-side twin of [isJunkDuration]: whether an END-of-file arrived with the playhead
/// implausibly short of the expected runtime. Catches the file that LIED about its duration (a sane
/// header, a 10-second payload): the early duration check passed, but the EOF position tells the
/// truth. Judged on the playhead (never the claimed duration) because the playhead is where playback
/// REALLY got to. With no expected runtime, an EOF under the absolute floor of BOTH playhead and
/// claimed duration is junk (a genuinely short file watched to its end); anything longer is trusted.
private fun isJunkEof(positionMs: Long, fileDurationMs: Long, playable: Playable): Boolean {
    if (playable.isTrailer) return false
    val expectedMs = playable.expectedDurationMs
    if (expectedMs > 0L) {
        val threshold = minOf(expectedMs / 2, expectedMs - EXPECTED_RUNTIME_SLACK_MS)
        return positionMs < threshold
    }
    return positionMs < JUNK_DURATION_FLOOR_MS && fileDurationMs < JUNK_DURATION_FLOOR_MS
}

/// Slack subtracted from the expected runtime for the mismatch threshold, so credit-less cuts,
/// ad-padded metadata runtimes, and slightly-off catalog numbers never condemn a real file.
private const val EXPECTED_RUNTIME_SLACK_MS = 10 * 60_000L

/// Conservative absolute junk floor when NO expected runtime is known: no real episode or movie
/// file is under 2 minutes, but plenty of legitimate short content sits just above it, so this only
/// catches outright samples/stubs. (Trailers never reach the check at all.)
private const val JUNK_DURATION_FLOOR_MS = 2 * 60_000L

internal val DefaultEmber = Color(0xFFD97706)

/// Tile width for a captured trickplay frame, in pixels. 480 == the `maxWidth` Apple passes on both of its
/// capture paths. The sheet builder downscales again to its own 320x180 tile, so this is only the
/// intermediate that keeps a 4K grab from being carried around at full size.
private const val TRICKPLAY_TILE_MAX_WIDTH = 480

/// Progress writeback cadence: report the live position to the host every few seconds while playing. The
/// host debounces the actual engine dispatch, so this only needs to be frequent enough that a save-on-
/// exit lands near where the viewer actually stopped.
private const val PROGRESS_REPORT_MS = 5_000L
