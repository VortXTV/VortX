package com.vortx.android.player

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.view.Display
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Audiotrack
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay10
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.model.Playable
import com.vortx.android.ui.theme.VortXGlass
import com.vortx.android.ui.theme.vortxGlass
import com.vortx.android.ui.theme.vortxGlassPanel
import com.vortx.android.ui.theme.vortxGlassProminent

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
    /// Whether the top scrim + control cluster and the bottom transport bar are drawn. The selection
    /// sheets and the error overlay are NOT gated on it: a sheet the viewer opened must survive an
    /// auto-hide tick, and an error must always be visible. The host owns the show/hide/auto-hide
    /// policy; defaults to always-visible so the chrome stays usable in isolation.
    controlsVisible: Boolean = true,
    /// Reported for chrome-internal continuous interactions (scrubber drags, sheet opens) so the host
    /// can re-arm its auto-hide timer. No-op by default.
    onInteraction: () -> Unit = {},
    onBack: () -> Unit,
    onTogglePause: () -> Unit,
    onSeek: (Long) -> Unit,
    /// Relative seek in milliseconds (negative = back): the +/-10s transport buttons drive this, and the
    /// host also wires the double-tap gesture to the same engine seam. See [PlayerEngine.seekBy].
    onSeekBy: (Long) -> Unit,
    onSelectAudio: (Int) -> Unit,
    onSelectSubtitle: (Int?) -> Unit,
    onSetSpeed: (Float) -> Unit,
    onToggleScaleMode: () -> Unit,
    onErrorRetry: () -> Unit,
    /// Player Lock: engages the host's touch-lock (controls hidden, taps/gestures ignored until the
    /// unlock affordance is used). Null hides the lock control entirely, keeping the chrome usable
    /// in isolation and on hosts that opt out (the TV shell, where D-pad focus makes a touch-lock
    /// meaningless).
    onLock: (() -> Unit)? = null,
    /// External subtitles offered by the installed subtitle add-ons for THIS title (the Apple
    /// `SubtitleAddons` union, fetched by the host once per load). Listed in the subtitle sheet
    /// under the file's embedded tracks; picking one mounts + selects it on the live engine via
    /// [onSelectAddonSubtitle]. Empty (the default) leaves the sheet exactly as before.
    addonSubtitles: List<AddonSubtitle> = emptyList(),
    onSelectAddonSubtitle: (AddonSubtitle) -> Unit = {},
    /// Community scrub preview: the thumbnail for a playback time (seconds), or null when this title has
    /// no community sheet (the common case for a title nobody has contributed yet, and always so while
    /// offline). MUST be cheap and synchronous -- it is called for every drag frame -- which is exactly
    /// what [com.vortx.android.trickplay.TrickplaySession.previewAt] guarantees: an in-memory crop of an
    /// already-downloaded sprite. Defaults to no preview so the chrome stays usable in isolation.
    scrubPreview: (Double) -> Bitmap? = { null },
    modifier: Modifier = Modifier,
) {
    // Which selection sheet (if any) is open. Local to the chrome; the engine never sees it.
    var openSheet by remember { mutableStateOf(ControlSheet.NONE) }

    Box(modifier = modifier) {
        // Top scrim so the title, back button, and controls stay legible over bright video.
        // Gated (with the transport bar below) on [controlsVisible]: this pair is what auto-hides.
        if (controlsVisible) Column(
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
                // Opening a sheet counts as interaction so the host's auto-hide timer re-arms.
                if (state.audioTracks.size > 1) {
                    ChromeIcon(Icons.Filled.Audiotrack, "Audio track") { onInteraction(); openSheet = ControlSheet.AUDIO }
                }
                ChromeIcon(Icons.Filled.Subtitles, "Subtitles") { onInteraction(); openSheet = ControlSheet.SUBTITLE }
                ChromeIcon(Icons.Filled.Speed, "Playback speed") { onInteraction(); openSheet = ControlSheet.SPEED }
                ChromeIcon(Icons.Filled.AspectRatio, "Aspect ratio", tint = if (scaleMode == VideoScaleMode.ZOOM) emberAccent else Color.White, onClick = onToggleScaleMode)
                // Player Lock: hides the chrome and freezes touch input so nothing mid-film seeks or
                // pauses by accident; the host draws the unlock affordance while locked.
                onLock?.let { lock ->
                    ChromeIcon(Icons.Filled.Lock, "Lock player controls") { lock() }
                }
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
        if (controlsVisible) TransportBar(
            state = state,
            emberAccent = emberAccent,
            onTogglePause = onTogglePause,
            onSeek = onSeek,
            onSeekBy = onSeekBy,
            onInteraction = onInteraction,
            scrubPreview = scrubPreview,
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
                    // Add-on subtitles, after the embedded tracks (Apple lists them the same way):
                    // picking one mounts it on the live engine, after which it also appears above as
                    // a regular (selected) track.
                    addonSubtitles.forEach { sub ->
                        add(SheetOption("${sub.lang} · ${sub.addonName}", false) { onSelectAddonSubtitle(sub) })
                    }
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

/// The relative-seek step (ms) for the transport's Replay10/Forward10 buttons. 10s matches the icon
/// glyphs and the host's double-tap gesture step.
private const val SEEK_STEP_MS = 10_000L

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
                // The selection sheet is a VortX glass panel (was a flat near-black fill): high-alpha warm
                // glass so track labels stay legible over bright video. Top-rounded, flush to the bottom.
                .vortxGlassPanel(RoundedCornerShape(topStart = 16.dp, topEnd = 16.dp))
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
                    // Primary recovery action as ember glass (was a solid accent slab).
                    modifier = Modifier
                        .vortxGlassProminent(shape = RoundedCornerShape(8.dp), tint = emberAccent)
                        .clickable(onClick = onRetry)
                        .padding(horizontal = 16.dp, vertical = 10.dp),
                )
                Text(
                    text = "Back",
                    color = Color.White,
                    fontSize = 15.sp,
                    // Secondary action as neutral VortX glass (was a flat white 12% fill).
                    modifier = Modifier
                        .vortxGlass(
                            shape = RoundedCornerShape(8.dp),
                            fillAlpha = VortXGlass.fieldFillAlpha,
                            shadow = VortXGlass.Shadow.flat,
                        )
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
    onSeekBy: (Long) -> Unit,
    /// Reported on every scrub drag frame so the host's auto-hide timer cannot expire mid-gesture and
    /// yank the slider out from under the finger. No-op by default.
    onInteraction: () -> Unit = {},
    scrubPreview: (Double) -> Bitmap? = { null },
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

    // The community scrub thumbnail for wherever the finger currently is. Recomputed only when the
    // scrubbed SECOND changes, not on every pixel of drag: `crop` allocates a bitmap, so keying on the raw
    // float would allocate on every frame of the gesture and make scrubbing the jankiest thing in the
    // player. One crop per second of scrubbed time is exactly the tile granularity anyway (tiles are 10s
    // apart), so nothing visible is lost. This mirrors the SkipButton's per-second recompute key.
    val scrubSeconds = if (duration > 0L) (scrubValue * duration / 1000.0) else 0.0
    val previewBitmap = remember(scrubbing, scrubSeconds.toLong()) {
        if (scrubbing && duration > 0L) scrubPreview(scrubSeconds) else null
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
        // Scrub preview, drawn ABOVE the transport row so it never covers the slider the finger is on.
        // Present only while dragging a title that actually has a community sheet; otherwise the row is
        // simply absent and the transport looks exactly as it does today.
        previewBitmap?.let { bmp ->
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = null,
                modifier = Modifier
                    .padding(start = 64.dp, bottom = 8.dp)
                    .size(width = 160.dp, height = 90.dp)
                    .clip(RoundedCornerShape(8.dp)),
            )
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onTogglePause) {
                Icon(
                    imageVector = if (state.isPaused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
                    contentDescription = if (state.isPaused) "Play" else "Pause",
                    tint = Color.White,
                )
            }
            // The +/-10s jump controls (the relative seek the scrubber physically cannot do: 10s of a
            // 2h film is under a pixel of slider travel). Gated like the slider on a known duration.
            IconButton(onClick = { onSeekBy(-SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    imageVector = Icons.Filled.Replay10,
                    contentDescription = "Back 10 seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
                )
            }
            IconButton(onClick = { onSeekBy(SEEK_STEP_MS) }, enabled = duration > 0L) {
                Icon(
                    imageVector = Icons.Filled.Forward10,
                    contentDescription = "Forward 10 seconds",
                    tint = if (duration > 0L) Color.White else Color.White.copy(alpha = 0.4f),
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
                    onInteraction()
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
        // The SOURCE / DOLBY VISION / speed badges as ember glass (was a near-opaque accent fill): the
        // prominent glass keeps the ember color but reads as tinted glass over the video frame.
        modifier = Modifier
            .vortxGlassProminent(shape = RoundedCornerShape(6.dp), tint = accent)
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
