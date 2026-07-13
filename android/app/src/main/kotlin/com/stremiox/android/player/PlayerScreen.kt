package com.stremiox.android.player

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.util.UnstableApi
import com.stremiox.android.model.Playable

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
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val currentOnBack by rememberUpdatedState(onBack)

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

    Box(modifier = modifier.fillMaxSize()) {
        engine.VideoSurface(modifier = Modifier.fillMaxSize(), emberArgb = emberAccent.toArgb())

        PlayerChrome(
            playable = playable,
            state = playerState,
            dolbyVisionAvailable = displaySupportsDolbyVision(context),
            emberAccent = emberAccent,
            onBack = currentOnBack,
            onTogglePause = engine::togglePause,
            onSeek = engine::seekTo,
            modifier = Modifier.fillMaxSize(),
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
