package com.vortx.android.cast

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.CastConnected
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.vortx.android.R

// Player chrome is always presented over video on a dark ground, so the cast surfaces paint their own dark
// obsidian panels rather than borrowing the app's theme tokens (which target the light browse shell).
private val CastPanel = Color(0xF2140F0D)
private val CastScrim = Color(0xF20E0B0A)

/// The Cast button for the player chrome, mirroring the Apple in-player AirPlay route-picker button. Self-
/// hides when there is nothing to cast to (no framework, or no receivers on the network), exactly like the
/// Cast SDK's own `MediaRouteButton`. Shows the connected glyph (ember-tinted) while a session is live.
/// Tapping it asks the host to open the route chooser.
@Composable
fun CastButton(state: CastPlaybackState, emberAccent: Color, onClick: () -> Unit) {
    val visible = state.availability != CastAvailability.UNAVAILABLE &&
        state.availability != CastAvailability.NO_DEVICES
    if (!visible) return
    val connected = state.isConnected || state.availability == CastAvailability.CONNECTED
    IconButton(onClick = onClick) {
        Icon(
            imageVector = if (connected) Icons.Filled.CastConnected else Icons.Filled.Cast,
            contentDescription = stringResource(R.string.cast_action),
            tint = if (connected) emberAccent else Color.White,
        )
    }
}

/// A self-contained Cast device chooser, presented as a dialog. It enumerates the reachable receivers via
/// `MediaRouter` (the Cast framework's own discovery), and selecting one hands the route to the framework,
/// which establishes the session that [CastManager] then observes and loads media onto. Compose-native so
/// it fits this AppCompat-free, Compose-only app (the SDK's View-based `MediaRouteChooserDialog` needs an
/// AppCompat/MediaRouter theme this app deliberately does not carry).
@Composable
fun CastRouteChooserSheet(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val router = remember(context) { runCatching { MediaRouter.getInstance(context) }.getOrNull() }
    val selector = remember {
        MediaRouteSelector.Builder()
            .addControlCategory(CastMediaControlIntent.categoryForCast(CastConfig.RECEIVER_APP_ID))
            .build()
    }
    var routes by remember { mutableStateOf(castRoutes(router, selector)) }

    DisposableEffect(router) {
        val activeRouter = router ?: return@DisposableEffect onDispose { }
        val callback = object : MediaRouter.Callback() {
            override fun onRouteAdded(r: MediaRouter, route: MediaRouter.RouteInfo) {
                routes = castRoutes(activeRouter, selector)
            }

            override fun onRouteRemoved(r: MediaRouter, route: MediaRouter.RouteInfo) {
                routes = castRoutes(activeRouter, selector)
            }

            override fun onRouteChanged(r: MediaRouter, route: MediaRouter.RouteInfo) {
                routes = castRoutes(activeRouter, selector)
            }
        }
        activeRouter.addCallback(selector, callback, MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN)
        onDispose { activeRouter.removeCallback(callback) }
    }

    Dialog(onDismissRequest = onDismiss) {
        Surface(shape = RoundedCornerShape(16.dp), color = CastPanel) {
            Column(modifier = Modifier.padding(20.dp).widthIn(min = 280.dp)) {
                Text(
                    text = stringResource(R.string.cast_choose_device),
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                )
                Spacer(Modifier.height(12.dp))
                if (routes.isEmpty()) {
                    Text(
                        text = stringResource(R.string.cast_searching),
                        color = Color.White.copy(alpha = 0.7f),
                        fontSize = 14.sp,
                    )
                } else {
                    routes.forEach { route ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    router?.selectRoute(route)
                                    onDismiss()
                                }
                                .padding(vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Filled.Cast, contentDescription = null, tint = Color.White)
                            Spacer(Modifier.width(14.dp))
                            Text(text = route.name, color = Color.White, fontSize = 15.sp)
                        }
                    }
                }
            }
        }
    }
}

/// The full-screen "Casting to X" surface shown while a receiver is connected. It covers the (paused) local
/// video with an opaque scrim, names the device, and hosts the [CastMiniController] transport row. Drawn
/// over the player chrome so it owns the screen while casting -- the local player is a silent remote control
/// at that point, matching how AirPlay video hands the timeline to the external display.
@Composable
fun CastOverlay(
    state: CastPlaybackState,
    emberAccent: Color,
    onBack: () -> Unit,
    onTogglePlay: () -> Unit,
    onSeekBy: (Long) -> Unit,
    onSeekTo: (Long) -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(CastScrim)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(16.dp),
    ) {
        IconButton(onClick = onBack, modifier = Modifier.align(Alignment.TopStart)) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = stringResource(R.string.cast_back),
                tint = Color.White,
            )
        }

        Column(
            modifier = Modifier.align(Alignment.Center),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(
                imageVector = Icons.Filled.CastConnected,
                contentDescription = null,
                tint = emberAccent,
                modifier = Modifier.size(72.dp),
            )
            Text(
                text = stringResource(
                    R.string.cast_casting_to,
                    state.deviceName ?: stringResource(R.string.cast_device_generic),
                ),
                color = Color.White,
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp,
            )
            if (state.isBuffering) {
                Text(
                    text = stringResource(R.string.cast_buffering),
                    color = Color.White.copy(alpha = 0.7f),
                    fontSize = 14.sp,
                )
            }
        }

        CastMiniController(
            state = state,
            emberAccent = emberAccent,
            onTogglePlay = onTogglePlay,
            onSeekBy = onSeekBy,
            onSeekTo = onSeekTo,
            onStop = onStop,
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth(),
        )
    }
}

/// The compact cast transport: a scrub bar plus play/pause, +/-10s, and stop-casting. Used inside
/// [CastOverlay] and reusable on its own (e.g. a persistent bar on a browse screen while casting). All
/// actions drive the [CastManager] through the callbacks the host wires in; it reads only [state].
@Composable
fun CastMiniController(
    state: CastPlaybackState,
    emberAccent: Color,
    onTogglePlay: () -> Unit,
    onSeekBy: (Long) -> Unit,
    onSeekTo: (Long) -> Unit,
    onStop: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(modifier = modifier.padding(horizontal = 8.dp)) {
        val duration = state.durationMs
        val fraction = if (duration > 0L) (state.positionMs.toFloat() / duration.toFloat()).coerceIn(0f, 1f) else 0f
        // Local drag state: while the finger is down the knob follows [dragValue] and NO seek is issued; a
        // single seek is committed on release. Without this the knob fights the receiver's live position and
        // every drag tick floods RemoteMediaClient.seek. Mirrors the local player's scrubber (PlayerChrome).
        var dragValue by remember { mutableStateOf<Float?>(null) }
        Slider(
            value = dragValue ?: fraction,
            onValueChange = { value -> dragValue = value },
            onValueChangeFinished = {
                val committed = dragValue
                if (committed != null && duration > 0L) onSeekTo((committed * duration).toLong())
                dragValue = null
            },
            enabled = duration > 0L,
            colors = SliderDefaults.colors(
                thumbColor = emberAccent,
                activeTrackColor = emberAccent,
                inactiveTrackColor = Color.White.copy(alpha = 0.3f),
            ),
        )
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = { onSeekBy(-SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    Icons.Filled.Replay10,
                    contentDescription = stringResource(R.string.cast_seek_back_10),
                    tint = Color.White,
                )
            }
            IconButton(onClick = onTogglePlay) {
                Icon(
                    imageVector = if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                    contentDescription = if (state.isPaused) {
                        stringResource(R.string.cast_play)
                    } else {
                        stringResource(R.string.cast_pause)
                    },
                    tint = Color.White,
                )
            }
            IconButton(onClick = { onSeekBy(SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    Icons.Filled.Forward10,
                    contentDescription = stringResource(R.string.cast_seek_forward_10),
                    tint = Color.White,
                )
            }
            IconButton(onClick = onStop) {
                Icon(
                    Icons.Filled.Stop,
                    contentDescription = stringResource(R.string.cast_stop),
                    tint = Color.White,
                )
            }
        }
    }
}

private fun castRoutes(
    router: MediaRouter?,
    selector: MediaRouteSelector,
): List<MediaRouter.RouteInfo> =
    router?.routes?.filter { it.matchesSelector(selector) && it.isEnabled && !it.isDefault } ?: emptyList()

private const val SEEK_STEP_MS = 10_000L
