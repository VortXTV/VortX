package com.stremiox.android.player

import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.stremiox.android.model.Playable

/// Fullscreen player. Owns one [ExoPlayer] for the lifetime of this composable and renders it through
/// a Media3 [PlayerView] configured as a SurfaceView. The controller chrome is restyled to the VortX
/// ember accent. Built deliberately thin: codec/HDR/DV handling is delegated to ExoPlayer's
/// [DefaultRenderersFactory], not hand-rolled here.
///
/// Dolby Vision: we do NOT pick codecs by hand. DefaultRenderersFactory already does the
/// DV -> HEVC/AVC/AV1 fallback based on the device's actual decoders. We only GATE the DV badge in
/// our own chrome on whether the display advertises Dolby Vision (see [displaySupportsDolbyVision]),
/// so we never promise DV on a panel that cannot present it.
@OptIn(UnstableApi::class)
@Composable
fun PlayerScreen(
    playable: Playable,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    emberAccent: Color = DefaultEmber,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    // rememberUpdatedState so the lifecycle observer always calls the latest onBack without
    // re-subscribing when the lambda identity changes across recompositions.
    val currentOnBack by rememberUpdatedState(onBack)

    // One ExoPlayer, built once, keyed to nothing so it survives recomposition. DefaultRenderersFactory
    // carries the built-in DV -> HEVC/AVC/AV1 codec fallback; we add nothing on top of it.
    val player = remember {
        ExoPlayer.Builder(context, DefaultRenderersFactory(context))
            .build()
            .apply {
                setMediaItem(MediaItem.fromUri(playable.url))
                playWhenReady = true
                if (playable.startPositionMs > 0L) seekTo(playable.startPositionMs)
                prepare()
            }
    }

    // Drive playback against the host lifecycle: pause when the screen is backgrounded, resume when it
    // returns, and release on destroy. SurfaceView-backed video must stop rendering off-screen.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_STOP -> player.pause()
                Lifecycle.Event.ON_DESTROY -> player.release()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            // Compose-side teardown: covers configuration-driven disposal that does not route through
            // ON_DESTROY. release() is idempotent, so the lifecycle path above is safe alongside this.
            player.release()
        }
    }

    Box(modifier = modifier.fillMaxSize()) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                PlayerView(ctx).apply {
                    this.player = player
                    // PlayerView's default surface_type is SURFACE_TYPE_SURFACE_VIEW, so constructing it
                    // in code (no TextureView attr) gives us a SurfaceView. SurfaceView is required for
                    // HDR/DV passthrough and avoids the extra GPU copy TextureView imposes; we never opt
                    // into TextureView.
                    setShowBuffering(PlayerView.SHOW_BUFFERING_WHEN_PLAYING)
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    setKeepContentOnPlayerReset(true)
                }
            },
            update = { view ->
                // Tint the built-in controller affordances (scrubber played-portion + handle) ember.
                view.applyEmberChrome(emberAccent)
            },
            onRelease = { view ->
                view.player = null
            },
        )

        PlayerChrome(
            playable = playable,
            dolbyVisionAvailable = displaySupportsDolbyVision(context),
            emberAccent = emberAccent,
            onBack = currentOnBack,
            modifier = Modifier.fillMaxSize(),
        )
    }

    // If we are dismissed because playback ended, hand control back to the detail page.
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) currentOnBack()
            }
        }
        player.addListener(listener)
        onDispose { player.removeListener(listener) }
    }
}

/// Tint the Media3 controller's scrubber to the ember accent. The PlayerView's default controller uses
/// a `DefaultTimeBar`; recoloring its played/scrubber colors is the lightest touch that keeps the
/// built-in transport behavior (seek, fast-forward, rewind) while matching VortX chrome.
@OptIn(UnstableApi::class)
private fun PlayerView.applyEmberChrome(ember: Color) {
    val bar = findViewById<View>(androidx.media3.ui.R.id.exo_progress)
    if (bar is androidx.media3.ui.DefaultTimeBar) {
        val argb = ember.toArgb()
        bar.setPlayedColor(argb)
        bar.setScrubberColor(argb)
    }
}

internal val DefaultEmber = Color(0xFFD97706)
