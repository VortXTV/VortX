package com.vortx.android.player

import android.app.Activity
import android.media.AudioManager
import android.provider.Settings
import android.view.WindowManager
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.BrightnessMedium
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FastRewind
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerInputScope
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vortx.android.ui.theme.vortxGlassProminent
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt

/// Touch gestures on the bare player surface (issue #77, the "Android feels bad" core): the three
/// standard mobile-player drags every touch player ships and VortX previously lacked.
///
///   - LEFT-half vertical drag  = screen brightness (window-level override, never the system setting)
///   - RIGHT-half vertical drag = media volume (STREAM_MUSIC, the same stream the hardware keys drive)
///   - horizontal drag          = seek, committed ON RELEASE with a live target-time HUD during the
///                                drag (committing per-frame would thrash both engines' demuxers)
///
/// The gesture surface is the SAME bare-video Box the tap/double-tap layer owns ([PlayerScreen] adds
/// this detector as a second `pointerInput` on it): Compose runs both detectors in parallel, and a
/// drag consuming its position changes makes the tap detector see consumed events and give up, so
/// drags never double-fire a tap. The chrome's own controls sit ABOVE this layer and keep their
/// events; the host disables the whole layer while locked, in PiP, and under the error overlay.
///
/// AXIS LATCH: the axis (horizontal seek vs vertical level) is classified ONCE per gesture, from the
/// accumulated deltas the moment their magnitude passes [PlayerGestureMath.AXIS_LOCK_PX], and stays
/// latched until the finger lifts. Without the latch a wandering vertical drag would drift into
/// seeking mid-adjust, which is exactly the misfire class the lock control exists to prevent.
///
/// All decision math lives in [PlayerGestureMath] (pure, unit-tested); this file's detector only
/// accumulates deltas and applies the math through the callbacks [PlayerScreen] wires to the engine,
/// the window, and the AudioManager. No persisted settings are added here, so there is no Apple
/// @AppStorage parity key to map (brightness/volume are live device state, not preferences).
internal object PlayerGestureMath {

    /// The gesture axis, latched once per drag.
    enum class Axis { HORIZONTAL, VERTICAL }

    /// Accumulated-delta magnitude (px) at which the axis is classified. Deliberately small: the
    /// system touch slop already gated the drag's START, so this only decides its DIRECTION.
    const val AXIS_LOCK_PX = 12f

    /// A full-width horizontal sweep seeks this far (ms). 120s across the whole screen keeps the
    /// gesture fine-grained enough for a sitcom and still useful on a 3-hour film (the scrubber and
    /// double-tap cover coarse jumps).
    const val FULL_WIDTH_SEEK_MS = 120_000L

    /// Classify the drag axis from the accumulated deltas, or null while still under [slopPx].
    /// A perfect diagonal resolves HORIZONTAL (seek is the least destructive misread: it previews
    /// and only commits on release, while a misread level change applies immediately).
    fun classifyAxis(totalDx: Float, totalDy: Float, slopPx: Float): Axis? {
        val ax = abs(totalDx)
        val ay = abs(totalDy)
        if (max(ax, ay) < slopPx) return null
        return if (ax >= ay) Axis.HORIZONTAL else Axis.VERTICAL
    }

    /// Whether a vertical drag starting at [startX] adjusts brightness (left half) or volume (right).
    fun isBrightnessSide(startX: Float, widthPx: Float): Boolean = startX < widthPx / 2f

    /// The seek target for a horizontal drag: [totalDx] across [widthPx] maps linearly onto
    /// [FULL_WIDTH_SEEK_MS] (via [fullWidthSeekMs], injectable for tests), clamped to [0, duration].
    /// An unknown duration (<= 0, still demuxing or live) clamps only the floor; the engine's own
    /// seek clamps the ceiling.
    fun seekTargetMs(
        startPositionMs: Long,
        totalDx: Float,
        widthPx: Float,
        durationMs: Long,
        fullWidthSeekMs: Long = FULL_WIDTH_SEEK_MS,
    ): Long {
        if (widthPx <= 0f) return startPositionMs.coerceAtLeast(0L)
        val deltaMs = (totalDx / widthPx * fullWidthSeekMs).toLong()
        val upper = if (durationMs > 0L) durationMs else Long.MAX_VALUE
        return (startPositionMs + deltaMs).coerceIn(0L, upper)
    }

    /// The adjusted 0..1 level for a vertical drag: dragging UP raises (screen-coordinate dy grows
    /// downward, hence the subtraction), a full-height sweep spans the whole range, and the result
    /// clamps to [0, 1].
    fun adjustedFraction(startFraction: Float, totalDy: Float, heightPx: Float): Float {
        if (heightPx <= 0f) return startFraction.coerceIn(0f, 1f)
        return (startFraction - totalDy / heightPx).coerceIn(0f, 1f)
    }

    /// Map a 0..1 fraction onto a stream-volume index in [0, maxIndex].
    fun volumeIndexFor(fraction: Float, maxIndex: Int): Int =
        (fraction * maxIndex).roundToInt().coerceIn(0, maxIndex)
}

/// What the gesture HUD renders while a drag is live. Null clears the HUD (finger lifted).
internal sealed interface PlayerGestureHud {
    /// Live seek preview: the target the release will commit, its delta from the drag's start
    /// position, and the duration (0 = unknown, the HUD then omits the total).
    data class Seek(val targetMs: Long, val deltaMs: Long, val durationMs: Long) : PlayerGestureHud

    /// Brightness level, 0..1, already applied to the window.
    data class Brightness(val fraction: Float) : PlayerGestureHud

    /// Volume level, 0..1 of the max stream index, already applied to the stream.
    data class Volume(val fraction: Float) : PlayerGestureHud
}

/// The drag detector [PlayerScreen] installs on the bare-video layer. Pure plumbing around
/// [PlayerGestureMath]: it accumulates deltas, latches the axis, applies brightness/volume LIVE
/// through the setters, previews the seek through [onHud], and commits the seek on release.
internal suspend fun PointerInputScope.detectPlayerDragGestures(
    currentPositionMs: () -> Long,
    currentDurationMs: () -> Long,
    /// Read the level the drag starts FROM (window brightness / stream-volume fraction, 0..1).
    currentBrightness: () -> Float,
    currentVolumeFraction: () -> Float,
    onBrightness: (Float) -> Unit,
    onVolumeFraction: (Float) -> Unit,
    onSeekCommit: (Long) -> Unit,
    onHud: (PlayerGestureHud?) -> Unit,
) {
    // Per-gesture state, reset at every drag start. detectDragGestures delivers one gesture at a
    // time, so plain locals captured by the lambdas are race-free.
    var totalDx = 0f
    var totalDy = 0f
    var startX = 0f
    var axis: PlayerGestureMath.Axis? = null
    var startPositionMs = 0L
    var startLevel = 0f
    var seekTargetMs = 0L

    detectDragGestures(
        onDragStart = { offset ->
            totalDx = 0f
            totalDy = 0f
            startX = offset.x
            axis = null
            seekTargetMs = 0L
        },
        onDrag = { change, dragAmount ->
            change.consume()
            totalDx += dragAmount.x
            totalDy += dragAmount.y
            if (axis == null) {
                axis = PlayerGestureMath.classifyAxis(totalDx, totalDy, PlayerGestureMath.AXIS_LOCK_PX)
                // Bank the baselines at the latch moment, not the down moment: the level/position
                // the viewer sees when the adjustment visibly begins is the one they adjust FROM.
                when (axis) {
                    PlayerGestureMath.Axis.HORIZONTAL -> startPositionMs = currentPositionMs()
                    PlayerGestureMath.Axis.VERTICAL -> {
                        startLevel = if (PlayerGestureMath.isBrightnessSide(startX, size.width.toFloat())) {
                            currentBrightness()
                        } else {
                            currentVolumeFraction()
                        }
                    }
                    null -> Unit
                }
            }
            when (axis) {
                PlayerGestureMath.Axis.HORIZONTAL -> {
                    val duration = currentDurationMs()
                    seekTargetMs = PlayerGestureMath.seekTargetMs(
                        startPositionMs = startPositionMs,
                        totalDx = totalDx,
                        widthPx = size.width.toFloat(),
                        durationMs = duration,
                    )
                    onHud(
                        PlayerGestureHud.Seek(
                            targetMs = seekTargetMs,
                            deltaMs = seekTargetMs - startPositionMs,
                            durationMs = duration,
                        ),
                    )
                }
                PlayerGestureMath.Axis.VERTICAL -> {
                    val fraction = PlayerGestureMath.adjustedFraction(startLevel, totalDy, size.height.toFloat())
                    if (PlayerGestureMath.isBrightnessSide(startX, size.width.toFloat())) {
                        onBrightness(fraction)
                        onHud(PlayerGestureHud.Brightness(fraction))
                    } else {
                        onVolumeFraction(fraction)
                        onHud(PlayerGestureHud.Volume(fraction))
                    }
                }
                null -> Unit
            }
        },
        onDragEnd = {
            if (axis == PlayerGestureMath.Axis.HORIZONTAL) onSeekCommit(seekTargetMs)
            onHud(null)
        },
        onDragCancel = { onHud(null) },
    )
}

/// Read the level a brightness drag starts from: the window's own override when one is set, else the
/// SYSTEM brightness mapped to 0..1, else mid. Never throws (the Settings read needs no permission,
/// but a hostile OEM shim failing it must not kill the gesture).
internal fun windowBrightnessFraction(activity: Activity?): Float {
    if (activity == null) return 0.5f
    val override = activity.window?.attributes?.screenBrightness
        ?: WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
    if (override in 0f..1f) return override
    return runCatching {
        Settings.System.getInt(activity.contentResolver, Settings.System.SCREEN_BRIGHTNESS) / 255f
    }.getOrDefault(0.5f).coerceIn(0f, 1f)
}

/// Apply a brightness fraction as the WINDOW's override (never the system setting, so leaving the
/// player leaves the device untouched). Floored just above zero: a truly 0 window is a black,
/// apparently dead screen mid-film. The player restores BRIGHTNESS_OVERRIDE_NONE on exit.
internal fun setWindowBrightnessFraction(activity: Activity?, fraction: Float) {
    val window = activity?.window ?: return
    // The platform's contract for applying window attributes is read-mutate-reassign; the reassign
    // is what dispatches the change, so this is the one sanctioned mutation shape.
    val attrs = window.attributes
    attrs.screenBrightness = fraction.coerceIn(MIN_WINDOW_BRIGHTNESS, 1f)
    window.attributes = attrs
}

/// Clear the window brightness override (back to the system level) when the player exits.
internal fun clearWindowBrightness(activity: Activity?) {
    val window = activity?.window ?: return
    val attrs = window.attributes
    attrs.screenBrightness = WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
    window.attributes = attrs
}

/// The current media-stream volume as a 0..1 fraction (0 when unavailable).
internal fun streamVolumeFraction(audioManager: AudioManager?): Float {
    val am = audioManager ?: return 0f
    val max = runCatching { am.getStreamMaxVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
    if (max <= 0) return 0f
    val current = runCatching { am.getStreamVolume(AudioManager.STREAM_MUSIC) }.getOrDefault(0)
    return (current.toFloat() / max).coerceIn(0f, 1f)
}

/// Apply a 0..1 fraction to the media stream. Flag 0: the gesture HUD is the volume UI, the system
/// panel over it would be doubled chrome. Never throws (setStreamVolume can SecurityException under
/// Do Not Disturb on some OEMs; the gesture then just does nothing).
internal fun setStreamVolumeFraction(audioManager: AudioManager?, fraction: Float) {
    val am = audioManager ?: return
    runCatching {
        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        if (max <= 0) return
        am.setStreamVolume(AudioManager.STREAM_MUSIC, PlayerGestureMath.volumeIndexFor(fraction, max), 0)
    }
}

/// The centered glass HUD a live drag shows: seek target ("+35s / 12:41"), or a brightness/volume
/// icon over a level bar. Same glass + type treatment as the player's other pills (unlock, skip).
@Composable
internal fun BoxScope.PlayerGestureHudOverlay(
    hud: PlayerGestureHud?,
    emberAccent: Color,
    modifier: Modifier = Modifier,
) {
    val current = hud ?: return
    Column(
        modifier = modifier
            .align(Alignment.Center)
            .vortxGlassProminent(shape = RoundedCornerShape(12.dp), tint = emberAccent)
            .padding(horizontal = 20.dp, vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        when (current) {
            is PlayerGestureHud.Seek -> {
                Icon(
                    imageVector = if (current.deltaMs >= 0L) Icons.Filled.FastForward else Icons.Filled.FastRewind,
                    contentDescription = if (current.deltaMs >= 0L) "Seeking forward" else "Seeking back",
                    tint = Color.White,
                    modifier = Modifier.size(28.dp),
                )
                Text(
                    text = signedSeconds(current.deltaMs),
                    color = Color.White,
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp,
                    modifier = Modifier.padding(top = 4.dp),
                )
                Text(
                    text = if (current.durationMs > 0L) {
                        "${formatTime(current.targetMs)} / ${formatTime(current.durationMs)}"
                    } else {
                        formatTime(current.targetMs)
                    },
                    color = Color.White.copy(alpha = 0.75f),
                    fontWeight = FontWeight.Medium,
                    fontSize = 13.sp,
                )
            }
            is PlayerGestureHud.Brightness -> LevelHudContent(
                icon = { tint ->
                    Icon(
                        imageVector = Icons.Filled.BrightnessMedium,
                        contentDescription = "Brightness",
                        tint = tint,
                        modifier = Modifier.size(28.dp),
                    )
                },
                fraction = current.fraction,
                emberAccent = emberAccent,
            )
            is PlayerGestureHud.Volume -> LevelHudContent(
                icon = { tint ->
                    Icon(
                        imageVector = if (current.fraction <= 0f) {
                            Icons.AutoMirrored.Filled.VolumeOff
                        } else {
                            Icons.AutoMirrored.Filled.VolumeUp
                        },
                        contentDescription = "Volume",
                        tint = tint,
                        modifier = Modifier.size(28.dp),
                    )
                },
                fraction = current.fraction,
                emberAccent = emberAccent,
            )
        }
    }
}

/// Shared icon + level bar + percent body for the brightness and volume HUDs.
@Composable
private fun LevelHudContent(
    icon: @Composable (Color) -> Unit,
    fraction: Float,
    emberAccent: Color,
) {
    icon(Color.White)
    Box(
        modifier = Modifier
            .padding(top = 10.dp)
            .width(140.dp)
            .height(4.dp)
            .background(Color.White.copy(alpha = 0.25f), RoundedCornerShape(2.dp)),
    ) {
        Box(
            modifier = Modifier
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .height(4.dp)
                .background(emberAccent, RoundedCornerShape(2.dp)),
        )
    }
    Text(
        text = "${(fraction * 100).roundToInt()}%",
        color = Color.White.copy(alpha = 0.85f),
        fontWeight = FontWeight.Medium,
        fontSize = 13.sp,
        modifier = Modifier.padding(top = 6.dp),
    )
}

/// "+35s" / "-1:10" style signed delta for the seek HUD.
private fun signedSeconds(deltaMs: Long): String {
    val sign = if (deltaMs < 0L) "-" else "+"
    val totalSeconds = abs(deltaMs) / 1000L
    val minutes = totalSeconds / 60
    val seconds = totalSeconds % 60
    return if (minutes > 0) "%s%d:%02d".format(sign, minutes, seconds) else "$sign${seconds}s"
}

/// The floor a brightness drag can reach: just above zero so the panel visibly dims without ever
/// reading as a dead screen.
private const val MIN_WINDOW_BRIGHTNESS = 0.01f
