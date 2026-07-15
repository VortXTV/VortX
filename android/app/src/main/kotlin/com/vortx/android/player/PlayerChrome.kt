package com.vortx.android.player

import android.content.Context
import android.os.Build
import android.view.Display
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Subtitles
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.model.Playable

/// The VortX-specific chrome layered over whichever [PlayerEngine] is live. It is fully engine-agnostic:
/// it renders the [PlayerState] snapshot and calls back through the transport + track lambdas, never
/// touching the engine directly. The same overlay drives libmpv and ExoPlayer identically, which is the
/// whole point of the [PlayerEngine] seam.
///
/// Controls (matching the Apple player's set as far as the Android engine supports it): back, source
/// title, DV / source badges, a top-right cluster (audio track, subtitle track, playback speed, aspect /
/// zoom), and a bottom play/pause + scrubber row. When the engine reports an error, an overlay offers a
/// return-to-sources fallback instead of a dead black frame.
@Composable
fun PlayerChrome(
    playable: Playable,
    state: PlayerState,
    dolbyVisionAvailable: Boolean,
    emberAccent: Color,
    speed: Float,
    scaleMode: VideoScaleMode,
    onBack: () -> Unit,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    onSelectAudio: (Int) -> Unit,
    onSelectSubtitle: (Int?) -> Unit,
    onSetSpeed: (Float) -> Unit,
    onToggleScaleMode: () -> Unit,
    onErrorRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Which selection sheet (if any) is open. Local to the chrome; the engine never sees it.
    var openSheet by remember { mutableStateOf(ControlSheet.NONE) }

    Box(modifier = modifier) {
        // Top scrim so the title, back button, and controls stay legible over bright video.
        Column(
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
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = 4.dp),
                )
                // Control cluster: audio (when >1 track), subtitles (always, includes Off), speed, aspect.
                if (state.audioTracks.size > 1) {
                    ChromeIcon(Icons.Filled.Audiotrack, "Audio track") { openSheet = ControlSheet.AUDIO }
                }
                ChromeIcon(Icons.Filled.Subtitles, "Subtitles") { openSheet = ControlSheet.SUBTITLE }
                ChromeIcon(Icons.Filled.Speed, "Playback speed") { openSheet = ControlSheet.SPEED }
                ChromeIcon(Icons.Filled.AspectRatio, "Aspect ratio", tint = if (scaleMode == VideoScaleMode.ZOOM) emberAccent else Color.White, onClick = onToggleScaleMode)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(start = 8.dp, top = 2.dp)) {
                if (playable.viaStreamingServer) ChromeBadge("SOURCE", emberAccent)
                // DV badge is GATED on the display actually advertising Dolby Vision. The ExoPlayer engine
                // still does its own DV codec fallback regardless; this badge is purely about not claiming
                // DV on a panel that cannot present it.
                if (dolbyVisionAvailable) ChromeBadge("DOLBY VISION", emberAccent)
                if (speed != 1.0f) ChromeBadge("${trimSpeed(speed)}x", emberAccent)
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

        // Selection sheets (audio / subtitle / speed) as a bottom overlay panel.
        when (openSheet) {
            ControlSheet.AUDIO -> ControlSelectionSheet(
                title = "Audio",
                options = state.audioTracks.map { SheetOption(trackLabel(it.title, it.lang), it.selected) { onSelectAudio(it.id) } },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SUBTITLE -> ControlSelectionSheet(
                title = "Subtitles",
                options = buildList {
                    add(SheetOption("Off", state.subtitleTracks.none { it.selected }) { onSelectSubtitle(null) })
                    state.subtitleTracks.forEach { t -> add(SheetOption(trackLabel(t.title, t.lang), t.selected) { onSelectSubtitle(t.id) }) }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.SPEED -> ControlSelectionSheet(
                title = "Playback speed",
                options = SPEED_PRESETS.map { preset ->
                    SheetOption(if (preset == 1.0f) "Normal" else "${trimSpeed(preset)}x", preset == speed) { onSetSpeed(preset) }
                },
                emberAccent = emberAccent,
                onDismiss = { openSheet = ControlSheet.NONE },
            )
            ControlSheet.NONE -> Unit
        }

        // Error-to-sources fallback: a failed source lands here instead of a dead black frame.
        if (state.hasError) {
            PlayerErrorOverlay(emberAccent = emberAccent, onRetry = onErrorRetry, onBack = onBack)
        }
    }
}

/// The selection sheets the chrome can open.
private enum class ControlSheet { NONE, AUDIO, SUBTITLE, SPEED }

/// The playback-speed presets offered in the speed sheet.
private val SPEED_PRESETS = listOf(0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 2.0f)

private data class SheetOption(val label: String, val selected: Boolean, val onPick: () -> Unit)

/// A bottom selection panel (scrim + card of rows). Deliberately a lightweight custom overlay rather than
/// a ModalBottomSheet: it renders over full-screen video, needs no experimental sheet-state plumbing, and
/// the scrim tap dismisses. The picked row invokes its action and closes the sheet.
@Composable
private fun ControlSelectionSheet(
    title: String,
    options: List<SheetOption>,
    emberAccent: Color,
    onDismiss: () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.4f))
            .clickable(onClick = onDismiss),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .background(Color(0xFF11110F))
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(text = title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 15.sp, modifier = Modifier.padding(bottom = 4.dp))
            if (options.isEmpty()) {
                Text(text = "None available", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp, modifier = Modifier.padding(vertical = 8.dp))
            }
            options.forEach { option ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .clickable { option.onPick(); onDismiss() }
                        .padding(vertical = 10.dp, horizontal = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = option.label,
                        color = if (option.selected) emberAccent else Color.White,
                        fontWeight = if (option.selected) FontWeight.SemiBold else FontWeight.Normal,
                        fontSize = 15.sp,
                        modifier = Modifier.weight(1f),
                    )
                    if (option.selected) {
                        Text(text = "•", color = emberAccent, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    }
                }
            }
        }
    }
}

/// The error fallback overlay: a centered message + a "Choose another source" action that returns to the
/// ranked source list, plus a plain back. Shown when [PlayerState.hasError] is set.
@Composable
private fun PlayerErrorOverlay(emberAccent: Color, onRetry: () -> Unit, onBack: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.85f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.padding(24.dp),
        ) {
            Text("This source didn't play", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
            Text(
                "It may be offline or unsupported. Pick another source to keep watching.",
                color = Color.White.copy(alpha = 0.75f),
                fontSize = 14.sp,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    text = "Choose another source",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(emberAccent)
                        .clickable(onClick = onRetry)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
                Text(
                    text = "Back",
                    color = Color.White,
                    fontSize = 15.sp,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color.White.copy(alpha = 0.12f))
                        .clickable(onClick = onBack)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
            }
        }
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

/// One control-cluster icon button (white, or [tint]-highlighted when its state is active).
@Composable
private fun ChromeIcon(icon: ImageVector, description: String, tint: Color = Color.White, onClick: () -> Unit) {
    IconButton(onClick = onClick) {
        Icon(imageVector = icon, contentDescription = description, tint = tint)
    }
}

/// A track label: prefer the add-on/embed title, append the language when both are present and differ.
private fun trackLabel(title: String, lang: String?): String {
    if (lang.isNullOrBlank() || title.contains(lang, ignoreCase = true)) return title.ifBlank { lang ?: "Track" }
    return "$title ($lang)"
}

/// Trim a speed multiplier for display: "1.5" not "1.5x1.0", "0.75" not "0.750000".
private fun trimSpeed(speed: Float): String {
    val s = "%.2f".format(speed).trimEnd('0').trimEnd('.')
    return s.ifEmpty { "1" }
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
