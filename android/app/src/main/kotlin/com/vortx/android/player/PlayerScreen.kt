package com.vortx.android.player

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.SkipNext
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
import com.vortx.android.integrations.ScrobbleService
import com.vortx.android.model.Playable
import com.vortx.android.model.TrackPreferencesStore
import com.vortx.android.skip.SegmentResolver
import com.vortx.android.skip.SkipSegment
import com.vortx.android.skip.SkipTimestampService
import com.vortx.android.trickplay.TrickplaySession
import com.vortx.android.ui.theme.vortxGlassProminent
import kotlinx.coroutines.delay

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
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnBack by rememberUpdatedState(onBack)
    val currentOnProgress by rememberUpdatedState(onProgress)
    val currentOnError by rememberUpdatedState(onError)
    val currentOnEnded by rememberUpdatedState(onEnded)

    // Chrome-owned view state (not engine state): the aspect/zoom mode passed to the surface, and the
    // current playback speed reflected in the speed control.
    var scaleMode by remember(playable.url) { mutableStateOf(VideoScaleMode.FIT) }
    var speed by remember(playable.url) { mutableStateOf(1.0f) }

    // CONTROLS AUTO-HIDE. The chrome (top scrim + title + transport bar) previously had no visibility
    // state at all, so it was drawn permanently over the video. Now: visible on entry, auto-hidden after
    // [CONTROLS_AUTO_HIDE_MS] of playback, re-shown (with the timer reset) by any interaction -- a tap on
    // bare video toggles it, the double-tap seek re-shows it, every transport/track action re-arms it, and
    // on TV any D-pad press while hidden re-reveals (consumed, so a blind press never fires an invisible
    // control). The error overlay and the selection sheets are NOT gated (see PlayerChrome).
    var controlsVisible by remember(playable.url) { mutableStateOf(true) }
    // Monotonic interaction counter: bumping it restarts the auto-hide countdown without toggling
    // visibility (the timer effect keys on it).
    var controlsInteractionTick by remember(playable.url) { mutableStateOf(0) }
    fun showControls() {
        controlsVisible = true
        controlsInteractionTick++
    }

    // Force-to-ExoPlayer latch: flipped when the mpv engine reports a surface failure, so the remember
    // key changes and the engine is rebuilt on ExoPlayer. Keyed alongside the playable url so a new
    // stream starts fresh.
    var forceExoPlayer by remember(playable.url) { mutableStateOf(false) }

    // Build the engine via the router. Rebuilt when the stream changes or the ExoPlayer latch flips.
    // Release the previous engine on dispose (idempotent).
    val engine = remember(playable.url, forceExoPlayer) {
        if (forceExoPlayer) {
            ExoPlayerEngine(context)
        } else {
            PlayerEngineRouter.engine(context, playable, engineOverride)
        }.also { it.load(playable) }
    }

    DisposableEffect(engine) {
        onDispose { engine.release() }
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
        }
    }

    // Drive the engine against the host lifecycle: drop decode / pause when backgrounded, resume when it
    // returns, release on destroy. Matches the Apple player's enterBackground/enterForeground.
    DisposableEffect(lifecycleOwner, engine) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> engine.onEnterBackground()
                Lifecycle.Event.ON_START -> engine.onEnterForeground()
                Lifecycle.Event.ON_DESTROY -> engine.release()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val playerState by engine.state.collectAsStateWithLifecycle()
    val latestState by rememberUpdatedState(playerState)

    // The auto-hide countdown: runs only while the controls are up and playback is actually rolling.
    // Paused, buffering, or errored playback keeps the controls on screen (hiding them over a stall or a
    // dead frame would look like a hang); any state flip or interaction tick restarts the countdown.
    LaunchedEffect(controlsVisible, controlsInteractionTick, playerState.isPaused, playerState.isBuffering, playerState.hasError) {
        if (!controlsVisible || playerState.isPaused || playerState.isBuffering || playerState.hasError) return@LaunchedEffect
        delay(CONTROLS_AUTO_HIDE_MS)
        controlsVisible = false
    }

    // Preference-driven auto track selection (the Android port of Apple TrackSelector): once the engine
    // reports its track list, pick the audio + subtitle track per the persisted TrackPreferences, exactly
    // ONCE per load. This closes the "manual select only" parity gap. A nil audio pick leaves the engine's
    // own default; a -1 subtitle pick means "off". Runs after the engine's own default selection, so it
    // overrides toward the user's language chain (e.g. a Turkish-only preference beats a French dub, #76).
    val trackPreferences = remember(playable.url) {
        TrackPreferencesStore(context, PerformanceMode.isConstrainedDevice(context)).current
    }
    var autoSelectDone by remember(playable.url) { mutableStateOf(false) }
    LaunchedEffect(playable.url, playerState.audioTracks, playerState.subtitleTracks) {
        if (autoSelectDone) return@LaunchedEffect
        val audioTracks = latestState.audioTracks
        val subtitleTracks = latestState.subtitleTracks
        if (audioTracks.isEmpty() && subtitleTracks.isEmpty()) return@LaunchedEffect
        val pick = TrackSelector.select(audioTracks, subtitleTracks, trackPreferences)
        pick.audioId?.let { engine.selectAudioTrack(it) }
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
    var skipSegments by remember(playable.url) { mutableStateOf<List<SkipSegment>>(emptyList()) }
    LaunchedEffect(playable.url, playerState.durationMs > 0L) {
        val ref = playable.mediaRef
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

    // Community trickplay (shared scrub previews). Three seams, all fail-soft, all keyed per title:
    //   1. KEY + FETCH  -- below, once the engine reports a real duration.
    //   2. CAPTURE      -- the wall-clock driver further down.
    //   3. SERVE        -- [previewAt] handed to the chrome's scrubber.
    // The session owns its own scope (it must outlive this composition to flush on exit), so it is only
    // remembered here, never scoped to the composition.
    val trickplay = remember(playable.url) { TrickplaySession(context) }

    // KEY + FETCH. Gated on a real reported duration because the content key is
    // sha1(imdb:season:episode:durationBucket) -- keying on 0 would compute the WRONG key and index a
    // different pool row. This is the same `durationMs > 0` gate the skip-segment fetch above uses, so it
    // is the established contract for "the engine now knows the title's real length".
    //
    // [TrickplaySession.configure] is idempotent and does the tmdb->imdb resolve itself: a hub/TMDB-catalog
    // play arrives with mediaRef.imdb == null and only a numeric tmdb id, and a tt-only content key would
    // silently drop it (the known past root cause of an account that contributed nothing from any device).
    LaunchedEffect(playable.url, playerState.durationMs > 0L) {
        val durationMs = latestState.durationMs
        if (durationMs <= 0L) return@LaunchedEffect
        trickplay.configure(playable.mediaRef, durationMs / 1000.0)
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
    LaunchedEffect(engine, playable.url) {
        while (true) {
            delay((TrickplaySession.CAPTURE_INTERVAL_S * 1000).toLong())
            val s = latestState
            if (s.isPaused || s.isBuffering || s.durationMs <= 0L) continue
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
    DisposableEffect(playable.url) {
        onDispose { trickplay.finishAndFlush() }
    }

    // When playback reaches its natural end, hand the ended signal to the host: the phone shell's Up
    // Next auto-advance for a series episode with a successor, or a plain return to the detail page
    // otherwise ([onEnded] defaults to [onBack]).
    LaunchedEffect(playerState.hasEnded) {
        if (playerState.hasEnded) currentOnEnded()
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
    LaunchedEffect(engine) {
        while (true) {
            delay(PROGRESS_REPORT_MS)
            val s = latestState
            if (!s.isPaused && s.durationMs > 0L) currentOnProgress(s.positionMs, s.durationMs)
        }
    }

    // Save-on-exit: emit the freshest position when the player leaves composition, so the host's
    // end-of-session write records where the viewer actually stopped.
    DisposableEffect(engine) {
        onDispose {
            val s = latestState
            if (s.durationMs > 0L) currentOnProgress(s.positionMs, s.durationMs)
        }
    }

    // External progress sync (Trakt / SIMKL). Drives scrobble at the play / pause / stop transitions off
    // the engine's live [PlayerState], through [ScrobbleService] which fans out to every connected
    // provider (Trakt live scrobble; SIMKL watched-on-finish). A [Playable] with no [Playable.mediaRef]
    // (the offline preview, an unmappable id) never scrobbles. [ScrobbleService]'s ops are fire-and-forget
    // on its own scope, so nothing here blocks playback and the stop still completes after this leaves
    // composition. See com.vortx.android.integrations.ScrobbleService.
    val scrobbleRef = playable.mediaRef
    // Latch the started/paused transitions so a play sends exactly one `start`, a resume sends one `start`,
    // and a pause sends one `pause`, rather than a scrobble on every recomposition.
    var scrobbleStarted by remember(playable.url) { mutableStateOf(false) }
    var scrobblePauseSent by remember(playable.url) { mutableStateOf(false) }
    LaunchedEffect(playerState.isPaused, playerState.durationMs > 0L, playerState.hasEnded) {
        val ref = scrobbleRef ?: return@LaunchedEffect
        ScrobbleService.init(context.applicationContext)
        val s = latestState
        if (s.durationMs <= 0L || s.hasEnded) return@LaunchedEffect
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
    DisposableEffect(playable.url) {
        onDispose {
            val ref = scrobbleRef
            if (ref != null && scrobbleStarted) {
                val s = latestState
                val progress = if (s.durationMs > 0L) s.positionMs.toDouble() / s.durationMs.toDouble() * 100.0 else 0.0
                // Stop records the watch server-side (Trakt at >= 80%, plus a SIMKL history write).
                ScrobbleService.stop(ref, progress)
            }
        }
    }

    // AudioFocus: pause when another app takes audio (a call, another player) so VortX never talks over
    // it, and resume on gain. Standard AudioManager focus request (minSdk 26 carries AudioFocusRequest).
    DisposableEffect(engine) {
        val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
            when (change) {
                AudioManager.AUDIOFOCUS_LOSS,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> engine.pause()
                AudioManager.AUDIOFOCUS_GAIN -> engine.play()
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
                if (!controlsVisible) {
                    // Back must keep meaning "leave the player", never be swallowed into a reveal.
                    if (event.key == Key.Back || event.key == Key.Escape) return@onKeyEvent false
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
        // mid-session ExoPlayer fallback rebinds the gesture to the live engine.
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(engine) {
                    detectTapGestures(
                        onTap = {
                            if (controlsVisible) controlsVisible = false else showControls()
                        },
                        onDoubleTap = { offset ->
                            val forward = offset.x >= size.width / 2
                            engine.seekBy(if (forward) DOUBLE_TAP_SEEK_MS else -DOUBLE_TAP_SEEK_MS)
                            showControls()
                        },
                    )
                },
        )

        PlayerChrome(
            playable = playable,
            state = playerState,
            dolbyVisionAvailable = displaySupportsDolbyVision(context),
            emberAccent = emberAccent,
            speed = speed,
            scaleMode = scaleMode,
            controlsVisible = controlsVisible,
            // Continuous interactions the chrome owns internally (scrubber drags, sheet opens) re-arm
            // the auto-hide timer through this seam; the discrete actions below re-arm via [showControls].
            onInteraction = { showControls() },
            onBack = currentOnBack,
            onTogglePause = { showControls(); engine.togglePause() },
            onSeek = { showControls(); engine.seekTo(it) },
            onSeekBy = { showControls(); engine.seekBy(it) },
            onSelectAudio = { showControls(); engine.selectAudioTrack(it) },
            onSelectSubtitle = { showControls(); engine.selectSubtitleTrack(it) },
            onSetSpeed = { newSpeed ->
                showControls()
                speed = newSpeed
                engine.setPlaybackSpeed(newSpeed)
            },
            onToggleScaleMode = {
                showControls()
                scaleMode = if (scaleMode == VideoScaleMode.FIT) VideoScaleMode.ZOOM else VideoScaleMode.FIT
            },
            onErrorRetry = currentOnError,
            // SERVE: the community scrub preview. Synchronous by contract -- the chrome calls this for
            // every drag frame, so it only ever crops an already-downloaded sprite in memory. Returns null
            // until (or unless) this title has a community sheet, and the scrubber then simply shows no
            // thumbnail, exactly as it does today.
            scrubPreview = trickplay::previewAt,
            modifier = Modifier.fillMaxSize(),
        )

        // The Skip Intro / Skip Recap / Skip Credits affordance, drawn OVER the chrome (declared last) at
        // the bottom-right, clear of the transport bar. Shows only while the playhead sits inside a
        // resolved segment; a tap seeks to the segment end. Engine-agnostic (drives the same [seekTo] the
        // scrubber does), so it works identically on libmpv and ExoPlayer.
        SkipButton(
            segments = skipSegments,
            positionMs = playerState.positionMs,
            emberAccent = emberAccent,
            onSkip = engine::seekTo,
        )
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
) {
    if (segments.isEmpty()) return
    val positionSec = positionMs / 1000.0
    // At most one segment applies at a time after the resolver's clamps (intro/recap sit early, credits/
    // preview in the back half); if two overlapped, the earliest-starting wins so "Skip Intro" beats a
    // stray late span.
    val active = remember(segments, positionSec.toLong()) {
        segments.filter { positionSec >= it.start && positionSec < it.end }.minByOrNull { it.start }
    } ?: return

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
            contentDescription = active.label,
            tint = Color.White,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = active.label,
            color = Color.White,
            fontWeight = FontWeight.SemiBold,
            fontSize = 14.sp,
        )
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

/// Resolve the hosting [Activity] from a Compose [LocalContext], which may be a [ContextWrapper] chain
/// (theme wrappers, configuration overrides). Null when unhosted (previews/tests), and every caller
/// treats null as "no orientation/insets control", never a crash.
private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

/// The double-tap relative-seek step (ms). Matches the transport bar's Replay10/Forward10 buttons.
private const val DOUBLE_TAP_SEEK_MS = 10_000L

/// How long the chrome stays up with no interaction while playback is rolling before it auto-hides.
/// 3.5s sits in the standard mobile-player band (3-4s); paused/buffering/error states never hide.
private const val CONTROLS_AUTO_HIDE_MS = 3_500L

internal val DefaultEmber = Color(0xFFD97706)

/// Tile width for a captured trickplay frame, in pixels. 480 == the `maxWidth` Apple passes on both of its
/// capture paths. The sheet builder downscales again to its own 320x180 tile, so this is only the
/// intermediate that keeps a 4K grab from being carried around at full size.
private const val TRICKPLAY_TILE_MAX_WIDTH = 480

/// Progress writeback cadence: report the live position to the host every few seconds while playing. The
/// host debounces the actual engine dispatch, so this only needs to be frequent enough that a save-on-
/// exit lands near where the viewer actually stopped.
private const val PROGRESS_REPORT_MS = 5_000L
