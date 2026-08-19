package com.vortx.android.ui.tv

import android.content.Context
import android.graphics.Color as AndroidColor
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.vortx.android.model.MetaItem
import com.vortx.android.model.Playable
import com.vortx.android.trailer.TrailerCoordinator
import com.vortx.android.ui.theme.VortXTheme
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/// The ambient, muted, looping in-hero trailer for the TV home cinematic hero -- the Android parity twin of
/// Apple `SourcesTV/TVInHeroTrailerView` + the `HomeHeroTrailerModel` focus-settle driver (#44). It is
/// purely decorative: it plays whatever the EXISTING trailer path ([TrailerCoordinator]) resolves, muted,
/// over the still Ken Burns backdrop, and never enters the D-pad focus path.
///
/// TRAILER SOURCING (reuse-only, no new fetch/extractor): the id comes from [heroTrailerYouTubeId] and the
/// playable from [TrailerCoordinator.trailerPlayable] -- the SAME client-direct route (YouTubeDirectResolver
/// + VXTrailerProxy, worker fallback) the detail/hero Trailer button already uses. Nothing here scrapes a
/// meta feed or extracts a trailer itself. When the focused item exposes no readily-available trailer id
/// (the common case today, see [heroTrailerYouTubeId]), the hero degrades to its slow Ken Burns backdrop.
///
/// LIFECYCLE: a dedicated lightweight [ExoPlayer] is built per resolved URL and released the moment the view
/// leaves composition (a focus move clears the [Playable]; navigating to Detail/Player or another tab tears
/// down the whole Home subtree), so the ambient player never leaks or keeps decoding behind the real player.

/// Seconds of settled focus before the ambient trailer resolves. Mirrors Apple `HomeHeroTrailerModel`'s 3s
/// settle: flicking catalog-to-catalog re-arms this timer, so only the item the viewer lands on resolves.
internal const val HERO_TRAILER_DWELL_MS = 3_000L

/// Cross-fade duration for revealing the clip over the still backdrop. Mirrors Apple's 0.6s reveal.
private const val HERO_TRAILER_FADE_MS = 600

/// Resolve the focused item's YouTube trailer id. Returns null until the Android meta model carries the
/// trailer field, so the home hero degrades to Ken Burns rather than a new trailer fetch path.
///
/// The Android [MetaItem] catalog-preview model does NOT yet carry `trailerStreams` / a trailer id (a
/// tier-1 model gap owned by a later round, documented in `model/TrailerRequest.kt`), and the task's
/// contract is reuse-only: do NOT add a new trailer fetch/extractor path. So today this returns null and the
/// hero shows its Ken Burns backdrop (graceful degrade). The instant [MetaItem] gains the field, returning it
/// here lights up the ambient trailer through the existing [TrailerCoordinator] with no other change.
internal fun heroTrailerYouTubeId(@Suppress("UNUSED_PARAMETER") item: MetaItem): String? = null

/// Dwell-gated ambient trailer resolution. Emits a [Playable] once focus has rested on [item] for
/// [HERO_TRAILER_DWELL_MS] AND a trailer id is readily available; emits null while settling, when disabled,
/// or when nothing is available. Keyed on the item id, so a focus move cancels the pending resolve before any
/// request fires (mirrors Apple `HomeHeroTrailerModel.focusChanged`).
@Composable
internal fun rememberHeroTrailerPlayable(item: MetaItem?, enabled: Boolean): Playable? {
    val context = LocalContext.current
    var playable by remember { mutableStateOf<Playable?>(null) }
    LaunchedEffect(item?.id, enabled) {
        playable = null
        if (!enabled) return@LaunchedEffect
        val current = item ?: return@LaunchedEffect
        val ytId = heroTrailerYouTubeId(current)?.takeIf { it.isNotEmpty() } ?: return@LaunchedEffect
        delay(HERO_TRAILER_DWELL_MS)
        // Fail-soft: a resolve error keeps the still backdrop (never a crash). CancellationException is
        // rethrown so a focus move that cancels this effect stays cancelled (coroutine contract).
        val resolved = try {
            TrailerCoordinator.trailerPlayable(
                context = context,
                youTubeId = ytId,
                title = current.name,
                imdbId = current.id.takeIf { it.startsWith("tt") },
                year = current.year,
                mediaType = current.type.id,
            )
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (error: Exception) {
            null
        }
        // The LaunchedEffect key already cancels on a focus move, so reaching here means focus still rests
        // on this item; a resolved clip paints, a miss leaves the Ken Burns backdrop.
        if (resolved != null) playable = resolved
    }
    return playable
}

/// The muted, looping, chromeless ambient trailer surface. Fades in over the still backdrop once the first
/// frame decodes; a load error keeps it hidden so the still art (and its Ken Burns) stays. Non-interactive.
@OptIn(UnstableApi::class)
@Composable
internal fun TvHeroAmbientTrailer(
    playable: Playable,
    reducedMotion: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val colors = VortXTheme.colors
    var showClip by remember(playable.url) { mutableStateOf(false) }
    var failed by remember(playable.url) { mutableStateOf(false) }

    val player = remember(playable.url) { buildAmbientTrailerPlayer(context, playable) }
    DisposableEffect(player) {
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                showClip = true
            }

            override fun onPlayerError(error: PlaybackException) {
                failed = true
            }
        }
        player.addListener(listener)
        onDispose {
            player.removeListener(listener)
            player.release()
        }
    }

    // Reveal alpha: instant when reduced motion, else a soft cross-fade. Hidden until the first frame and
    // dropped back to 0 on a load failure, so a missing/slow/dead clip never leaves a black band.
    val revealAlpha = if (showClip && !failed) 1f else 0f
    val fadeSpec = if (reducedMotion) snap<Float>() else tween(HERO_TRAILER_FADE_MS)
    val animatedAlpha by animateFloatAsState(
        targetValue = revealAlpha,
        animationSpec = fadeSpec,
        label = "heroTrailerReveal",
    )

    Box(modifier) {
        AndroidView(
            factory = { ctx ->
                PlayerView(ctx).apply {
                    useController = false
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    // Transparent before the first frame so the still backdrop shows through, never a black slab.
                    setShutterBackgroundColor(AndroidColor.TRANSPARENT)
                    setBackgroundColor(AndroidColor.TRANSPARENT)
                    this.player = player
                }
            },
            modifier = Modifier.fillMaxSize().alpha(animatedAlpha),
        )
        // A deeper scrim tuned for moving art (a clip has bright motion the still art does not), so the
        // logo / meta / synopsis painted ABOVE this layer stay legible once it fades in. Mirrors the extra
        // top + left scrim Apple's `TVInHeroTrailerView` carries.
        Box(
            Modifier
                .fillMaxSize()
                .alpha(animatedAlpha)
                .background(
                    Brush.verticalGradient(
                        0.0f to colors.canvas.copy(alpha = 0.35f),
                        0.45f to Color.Transparent,
                        0.80f to colors.canvas.copy(alpha = 0.55f),
                        1.0f to colors.canvas,
                    ),
                ),
        )
        Box(
            Modifier
                .fillMaxSize()
                .alpha(animatedAlpha)
                .background(
                    Brush.horizontalGradient(
                        0f to colors.canvas.copy(alpha = 0.6f),
                        0.6f to Color.Transparent,
                    ),
                ),
        )
    }
}

/// Build a lightweight muted, looping [ExoPlayer] for the ambient clip. Mirrors the media-source
/// construction in [com.vortx.android.player.ExoPlayerEngine.load]: an adaptive client-resolved trailer is a
/// video + audio merge over a UA-locked data source; a muxed / worker trailer is a single stream (with its
/// UA when set). Muted and set to loop the whole clip; never scrobbles (decorative).
@OptIn(UnstableApi::class)
private fun buildAmbientTrailerPlayer(context: Context, playable: Playable): ExoPlayer {
    val appContext = context.applicationContext
    val player = ExoPlayer.Builder(appContext).build().apply {
        volume = 0f
        repeatMode = Player.REPEAT_MODE_ALL
        playWhenReady = true
    }
    val ua = playable.userAgent?.takeIf { it.isNotEmpty() }
    when {
        playable.audioUrl != null -> {
            // Adaptive (video-only + audio-only) client trailer: merge both legs over one UA-locked source
            // (the UA/URL lockstep googlevideo requires; both legs are already the loopback range-proxy URLs).
            val http = DefaultHttpDataSource.Factory().apply {
                ua?.let { setUserAgent(it) }
                setAllowCrossProtocolRedirects(true)
            }
            val video = ProgressiveMediaSource.Factory(http)
                .createMediaSource(MediaItem.fromUri(playable.url))
            val audio = ProgressiveMediaSource.Factory(http)
                .createMediaSource(MediaItem.fromUri(playable.audioUrl))
            player.setMediaSource(MergingMediaSource(video, audio))
        }

        ua != null -> {
            // Muxed client trailer (single proxied url) still needs the minting UA as the raw-URL fallback.
            val http = DefaultHttpDataSource.Factory().apply {
                setUserAgent(ua)
                setAllowCrossProtocolRedirects(true)
            }
            player.setMediaSource(
                DefaultMediaSourceFactory(appContext)
                    .setDataSourceFactory(http)
                    .createMediaSource(MediaItem.fromUri(playable.url)),
            )
        }

        else -> {
            // Worker-fallback trailer: a clean single remote stream, no special UA.
            player.setMediaItem(MediaItem.fromUri(playable.url))
        }
    }
    player.prepare()
    return player
}
