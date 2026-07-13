package com.vortx.android.player

import android.content.Context
import android.os.Build
import android.view.Display
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.model.Playable

/// The VortX-specific chrome layered over whichever [PlayerEngine] is live. It is fully engine-agnostic:
/// it renders the [PlayerState] snapshot (position / duration / paused) and calls back through
/// [onTogglePause] / [onSeek], never touching the engine directly. The same overlay drives libmpv and
/// ExoPlayer identically, which is the whole point of the [PlayerEngine] seam.
///
/// Both engines host their surface with their built-in controller HIDDEN (ExoPlayer sets
/// `useController = false`; mpv draws none), so this overlay owns transport: a back affordance, the source
/// title, the DV / source badges, and a play/pause + scrubber row driven by [state].
@Composable
fun PlayerChrome(
    playable: Playable,
    state: PlayerState,
    dolbyVisionAvailable: Boolean,
    emberAccent: Color,
    onBack: () -> Unit,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier = modifier) {
        // Top scrim so the title and back button stay legible over bright video.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(
                        listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent)
                    )
                )
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 8.dp, vertical = 8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Back",
                        tint = Color.White,
                    )
                }
                Text(
                    text = playable.title,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    maxLines = 1,
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.align(Alignment.CenterEnd),
            ) {
                if (playable.viaStreamingServer) {
                    ChromeBadge("SOURCE", emberAccent)
                }
                // DV badge is GATED on the display actually advertising Dolby Vision. The ExoPlayer engine
                // still does its own DV codec fallback regardless; this badge is purely about not claiming
                // DV on a panel that cannot present it.
                if (dolbyVisionAvailable) {
                    ChromeBadge("DOLBY VISION", emberAccent)
                }
            }
        }

        // Bottom transport: play/pause + scrubber, driven entirely by [state] (engine-agnostic).
        TransportBar(
            state = state,
            emberAccent = emberAccent,
            onTogglePause = onTogglePause,
            onSeek = onSeek,
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter),
        )
    }
}

/// The bottom play/pause + scrubber row. Reflects [PlayerState] and reports scrubs back via [onSeek].
/// While the user is dragging, the slider follows the finger locally; on release it seeks the engine, so
/// a mid-drag position update from the engine does not fight the gesture.
@Composable
private fun TransportBar(
    state: PlayerState,
    emberAccent: Color,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    var scrubbing by remember { mutableStateOf(false) }
    var scrubValue by remember { mutableStateOf(0f) }

    val duration = state.durationMs.coerceAtLeast(0L)
    val position = state.positionMs.coerceIn(0L, if (duration > 0L) duration else Long.MAX_VALUE)
    val sliderValue = when {
        scrubbing -> scrubValue
        duration > 0L -> position.toFloat() / duration.toFloat()
        else -> 0f
    }

    Column(
        modifier = modifier
            .background(
                Brush.verticalGradient(
                    listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f))
                )
            )
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onTogglePause) {
                Icon(
                    imageVector = if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                    contentDescription = if (state.isPaused) "Play" else "Pause",
                    tint = Color.White,
                )
            }
            Text(
                text = formatTime(if (scrubbing && duration > 0L) (scrubValue * duration).toLong() else position),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.width(52.dp),
            )
            Slider(
                value = sliderValue,
                onValueChange = {
                    scrubbing = true
                    scrubValue = it
                },
                onValueChangeFinished = {
                    if (duration > 0L) onSeek((scrubValue * duration).toLong())
                    scrubbing = false
                },
                enabled = duration > 0L,
                colors = SliderDefaults.colors(
                    thumbColor = emberAccent,
                    activeTrackColor = emberAccent,
                ),
                modifier = Modifier.weight(1f),
            )
            Text(
                text = formatTime(duration),
                color = Color.White,
                fontSize = 12.sp,
                modifier = Modifier.width(52.dp),
            )
        }
    }
}

/// Milliseconds -> H:MM:SS / M:SS. Kept local; no dependency on any engine.
private fun formatTime(ms: Long): String {
    val totalSeconds = (ms / 1000).coerceAtLeast(0L)
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds % 3600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
        "%d:%02d:%02d".format(hours, minutes, seconds)
    } else {
        "%d:%02d".format(minutes, seconds)
    }
}

@Composable
private fun ChromeBadge(text: String, accent: Color) {
    Text(
        text = text,
        color = Color.White,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(accent.copy(alpha = 0.85f))
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

/// True when the device's default display advertises Dolby Vision in its HDR capabilities. This gates
/// the DV badge only; it does not influence decoding (the ExoPlayer engine's DefaultRenderersFactory
/// handles the codec fallback). Uses the modern Display API on R+ and reports false on older releases
/// where the capability query is unavailable.
fun displaySupportsDolbyVision(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
    val display: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        context.display
    } else {
        @Suppress("DEPRECATION")
        (context.getSystemService(Context.WINDOW_SERVICE) as? android.view.WindowManager)?.defaultDisplay
    }
    @Suppress("DEPRECATION")
    val hdr = display?.hdrCapabilities ?: return false
    return hdr.supportedHdrTypes.contains(Display.HdrCapabilities.HDR_TYPE_DOLBY_VISION)
}
