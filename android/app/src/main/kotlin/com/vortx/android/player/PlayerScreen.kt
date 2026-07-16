package com.vortx.android.player

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnBack by rememberUpdatedState(onBack)
    val currentOnProgress by rememberUpdatedState(onProgress)
    val currentOnError by rememberUpdatedState(onError)

    // Chrome-owned view state (not engine state): the aspect/zoom mode passed to the surface, and the
    // current playback speed reflected in the speed control.
    var scaleMode by remember(playable.url) { mutableStateOf(VideoScaleMode.FIT) }
    var speed by remember(playable.url) { mutableStateOf(1.0f) }

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

    // When playback ends, hand control back to the detail page.
    LaunchedEffect(playerState.hasEnded) {
        if (playerState.hasEnded) currentOnBack()
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

    Box(modifier = modifier.fillMaxSize()) {
        engine.VideoSurface(modifier = Modifier.fillMaxSize(), emberArgb = emberAccent.toArgb(), scaleMode = scaleMode)

        PlayerChrome(
            playable = playable,
            state = playerState,
            dolbyVisionAvailable = displaySupportsDolbyVision(context),
            emberAccent = emberAccent,
            speed = speed,
            scaleMode = scaleMode,
            onBack = currentOnBack,
            onTogglePause = engine::togglePause,
            onSeek = engine::seekTo,
            onSelectAudio = engine::selectAudioTrack,
            onSelectSubtitle = engine::selectSubtitleTrack,
            onSetSpeed = { newSpeed ->
                speed = newSpeed
                engine.setPlaybackSpeed(newSpeed)
            },
            onToggleScaleMode = {
                scaleMode = if (scaleMode == VideoScaleMode.FIT) VideoScaleMode.ZOOM else VideoScaleMode.FIT
            },
            onErrorRetry = currentOnError,
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

internal val DefaultEmber = Color(0xFFD97706)

/// Progress writeback cadence: report the live position to the host every few seconds while playing. The
/// host debounces the actual engine dispatch, so this only needs to be frequent enough that a save-on-
/// exit lands near where the viewer actually stopped.
private const val PROGRESS_REPORT_MS = 5_000L
