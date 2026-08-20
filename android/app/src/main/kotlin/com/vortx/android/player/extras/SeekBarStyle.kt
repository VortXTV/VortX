package com.vortx.android.player.extras

import android.content.Context
import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.input.pointer.pointerInput
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * User-selectable look for the player seek bar, the Android port of Apple `app/SourcesShared/SeekBarStyle.swift`.
 *
 * The GEOMETRY is identical across styles (the played fraction, the knob, the chapter ticks, and the skip
 * bands all live in the player and never change); only the TRACK rendering swaps, so choosing a style can
 * never affect scrubbing. Every animated style derives its motion from a CONTINUOUS clock (Compose's
 * infinite-animation frame time), not a repeating tween, so a "Wave" actually travels and never seams;
 * static styles ignore the clock so the per-frame redraw can be paused.
 *
 * DIVERGENCE from Apple, deliberate and documented: Apple draws its glows with a real `GraphicsContext`
 * blur filter. Compose has no cheap per-frame blur in a `DrawScope` (a real blur needs a `graphicsLayer`
 * RenderEffect, API 31+, and a layer allocation per frame), so the glow styles here approximate the halo
 * with two or three layered translucent draws. The motion and progress reading are identical; only the
 * softness of the halo differs, which is a visual nicety, not behavior.
 *
 * Device-wide setting persisted under Apple's EXACT key and value strings ([KEY], the `storageValue`s), in
 * the shared `vortx_settings` file, so a style chosen on Apple or web rides the same cross-device settings
 * blob and takes effect here with no UI involved (the same-key mandate).
 */
enum class SeekBarStyle(val storageValue: String, val displayName: String, val animated: Boolean) {
    CLASSIC("classic", "Classic", false),
    GRADIENT("gradient", "Gradient Sweep", true),
    GLOW("glow", "Breathing Glow", true),
    WAVE("wave", "Wave", true),
    HEARTBEAT("heartbeat", "Heartbeat", true),
    PULSE("pulse", "Ripple", true),
    DOTS("dots", "Beads", true),
    EQUALIZER("equalizer", "Equalizer", true),
    MINIMAL("minimal", "Minimal", false),
    NEON("neon", "Neon Comet", true),
    RIBBON("ribbon", "Liquid", true),
    COMET("comet", "Comet", true),
    SEGMENTS("segments", "Runner", true),
    LADDER("ladder", "Spectrum", true);

    companion object {
        /** UserDefaults/SharedPreferences key, byte-for-byte Apple's (`SeekBarStyle.storageKey`). */
        const val KEY = "stremiox.player.seekBarStyle"

        private const val SETTINGS_FILE = "vortx_settings"

        /** Unknown/absent reads back as [CLASSIC], matching Apple's default for older installs. */
        fun fromStorage(raw: String?): SeekBarStyle = entries.firstOrNull { it.storageValue == raw } ?: CLASSIC

        fun current(context: Context): SeekBarStyle = fromStorage(
            context.applicationContext
                .getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
                .getString(KEY, null),
        )

        fun setCurrent(context: Context, style: SeekBarStyle) {
            context.applicationContext
                .getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY, style.storageValue)
                .apply()
        }

        /** The choices Settings offers, in Apple's declaration order. `storageValue` persists. */
        val choices: List<SeekBarStyle> = entries.toList()
    }
}

/**
 * A skippable segment drawn as a coloured band on the scrubber (intro / recap / credits / preview). Seconds,
 * not fractions, so the caller does not recompute on every duration tick; [StyledScrubber] converts against
 * its `durationSeconds`. The colour is chosen by the caller from the segment kind (kept out of this file so
 * the drawing layer stays decoupled from the skip model). Mirrors the skip bands the Apple player overlays.
 */
data class SkipBand(val startSeconds: Double, val endSeconds: Double, val color: Color)

/**
 * The full player scrubber: a styled track ([SeekBarStyle]) with a YouTube-style buffered-ahead band,
 * chapter ticks, skip bands, and a grabbable knob, owning its own drag gesture. The Android analogue of the
 * Apple player's `SeekBarTrack` + its knob/tick/band overlays, collapsed into one interactive control so the
 * geometry the drawing uses is exactly the geometry the finger scrubs (no thumb-radius mismatch).
 *
 * Controlled component: [displayProgress] is what to draw (the caller passes the live position fraction, or
 * the in-flight scrub fraction while dragging). Drag reports come back through [onScrubStart] / [onScrub]
 * (live fraction) / [onScrubEnd] (final fraction), leaving the seek policy with the caller.
 */
@Composable
fun StyledScrubber(
    displayProgress: Float,
    bufferedFraction: Float,
    durationSeconds: Double,
    accent: Color,
    style: SeekBarStyle,
    animated: Boolean,
    chapterStartsSeconds: List<Double>,
    skipBands: List<SkipBand>,
    enabled: Boolean,
    onScrubStart: () -> Unit,
    onScrub: (Float) -> Unit,
    onScrubEnd: (Float) -> Unit,
    modifier: Modifier = Modifier,
    trackColor: Color = Color.White.copy(alpha = 0.22f),
) {
    // Continuous motion clock (seconds, monotonic, never resets), paused for static styles and while the
    // caller freezes motion (e.g. playback paused). withInfiniteAnimationFrameMillis calls back every frame
    // and never returns; LaunchedEffect cancels it when a key changes or on dispose.
    var timeSeconds by remember { mutableStateOf(0.0) }
    LaunchedEffect(style, animated) {
        if (animated && style.animated) {
            withInfiniteAnimationFrameMillis { frameMs -> timeSeconds = frameMs / 1000.0 }
        }
    }

    val progress = displayProgress.coerceIn(0f, 1f)
    val buffered = bufferedFraction.coerceIn(0f, 1f)

    val gesture = if (!enabled) {
        Modifier
    } else {
        Modifier
            .pointerInput(Unit) {
                detectTapGestures { offset ->
                    val fraction = (offset.x / size.width.toFloat()).coerceIn(0f, 1f)
                    onScrubStart()
                    onScrub(fraction)
                    onScrubEnd(fraction)
                }
            }
            .pointerInput(Unit) {
                var lastFraction = progress
                detectHorizontalDragGestures(
                    onDragStart = { offset ->
                        lastFraction = (offset.x / size.width.toFloat()).coerceIn(0f, 1f)
                        onScrubStart()
                        onScrub(lastFraction)
                    },
                    onHorizontalDrag = { change, _ ->
                        lastFraction = (change.position.x / size.width.toFloat()).coerceIn(0f, 1f)
                        onScrub(lastFraction)
                    },
                    onDragEnd = { onScrubEnd(lastFraction) },
                    onDragCancel = { onScrubEnd(lastFraction) },
                )
            }
    }

    Canvas(modifier = modifier.then(gesture)) {
        drawSeekBar(style, timeSeconds, progress, accent, trackColor)
        drawBufferedBand(progress, buffered, trackColor)
        drawSkipBands(durationSeconds, skipBands)
        drawChapterTicks(durationSeconds, chapterStartsSeconds)
        drawKnob(progress, accent)
    }
}

// ---------------------------------------------------------------------------------------------------
// Overlays shared by every style (buffered band, skip bands, chapter ticks, knob).
// ---------------------------------------------------------------------------------------------------

/** The grey loaded-but-not-yet-played hint, from the playhead to the buffered edge. Apple `bufferedBand`. */
private fun DrawScope.drawBufferedBand(progress: Float, buffered: Float, track: Color) {
    if (buffered <= progress) return
    val h = size.height
    val th = max(3f, h * 0.30f)
    val y = (h - th) / 2f
    val startX = size.width * progress
    val endX = size.width * min(1f, buffered)
    val bw = max(0f, endX - startX)
    if (bw <= 0.5f) return
    drawRoundRect(
        color = Color.White.copy(alpha = 0.42f),
        topLeft = Offset(startX, y),
        size = Size(bw, th),
        cornerRadius = CornerRadius(th / 2f),
    )
}

/** Translucent coloured bands for skippable intro/recap/credits/preview segments, over the track. */
private fun DrawScope.drawSkipBands(durationSeconds: Double, bands: List<SkipBand>) {
    if (durationSeconds <= 0.0 || bands.isEmpty()) return
    val h = size.height
    val th = max(4f, h * 0.5f)
    val y = (h - th) / 2f
    bands.forEach { band ->
        val start = (band.startSeconds / durationSeconds).toFloat().coerceIn(0f, 1f)
        val end = (band.endSeconds / durationSeconds).toFloat().coerceIn(0f, 1f)
        val bw = max(0f, (end - start) * size.width)
        if (bw <= 0.5f) return@forEach
        drawRoundRect(
            color = band.color.copy(alpha = 0.55f),
            topLeft = Offset(size.width * start, y),
            size = Size(bw, th),
            cornerRadius = CornerRadius(th / 4f),
        )
    }
}

/** Thin vertical ticks at chapter boundaries (the interior ones; the 0 and end edges are skipped). */
private fun DrawScope.drawChapterTicks(durationSeconds: Double, chapterStartsSeconds: List<Double>) {
    if (durationSeconds <= 0.0 || chapterStartsSeconds.size < 2) return
    val h = size.height
    chapterStartsSeconds.forEach { startSec ->
        val f = (startSec / durationSeconds).toFloat()
        if (f <= 0.001f || f >= 0.999f) return@forEach
        val x = size.width * f
        drawLine(
            color = Color.White.copy(alpha = 0.85f),
            start = Offset(x, h * 0.15f),
            end = Offset(x, h * 0.85f),
            strokeWidth = 2f,
        )
    }
}

/** A white grab-knob with an accent ring at the playhead. Doubles as the unambiguous progress marker. */
private fun DrawScope.drawKnob(progress: Float, accent: Color) {
    val cx = size.width * progress
    val cy = size.height / 2f
    drawCircle(color = accent.copy(alpha = 0.35f), radius = size.height * 0.42f, center = Offset(cx, cy))
    drawCircle(color = accent, radius = size.height * 0.26f, center = Offset(cx, cy))
    drawCircle(color = Color.White, radius = size.height * 0.18f, center = Offset(cx, cy))
}

// ---------------------------------------------------------------------------------------------------
// Style dispatch + renderers (faithful ports of Apple's SeekBarRenderer, blur approximated by layering).
// ---------------------------------------------------------------------------------------------------

private fun DrawScope.drawSeekBar(style: SeekBarStyle, t: Double, p: Float, accent: Color, track: Color) {
    when (style) {
        SeekBarStyle.CLASSIC -> capsule(p, accent, track, thickness = 1.0f)
        SeekBarStyle.MINIMAL -> capsule(p, accent, track, thickness = 0.4f)
        SeekBarStyle.GLOW -> breathingGlow(t, p, accent, track)
        SeekBarStyle.GRADIENT -> gradientSweep(t, p, accent, track)
        SeekBarStyle.WAVE -> wave(t, p, accent, track)
        SeekBarStyle.HEARTBEAT -> heartbeat(t, p, accent, track)
        SeekBarStyle.PULSE -> ripple(t, p, accent, track)
        SeekBarStyle.DOTS -> beads(t, p, accent, track)
        SeekBarStyle.EQUALIZER -> equalizer(t, p, accent, track)
        SeekBarStyle.NEON -> comet(t, p, accent, track, neon = true)
        SeekBarStyle.COMET -> comet(t, p, accent, track, neon = false)
        SeekBarStyle.RIBBON -> liquid(t, p, accent, track)
        SeekBarStyle.SEGMENTS -> runner(t, p, accent, track)
        SeekBarStyle.LADDER -> spectrum(t, p, accent, track)
    }
}

/** Centred capsule track + played fill, optional layered halo. Base of classic / minimal / glow. */
private fun DrawScope.capsule(p: Float, accent: Color, track: Color, thickness: Float, glow: Float = 0f) {
    val w = size.width
    val h = size.height
    val th = max(4f, h * 0.42f * thickness)
    val y = (h - th) / 2f
    drawRoundRect(track, Offset(0f, y), Size(w, th), CornerRadius(th / 2f))
    val fw = max(0f, w * p)
    if (glow > 0f) {
        // Layered translucent halo (blur approximation): two wider, fainter fills under the crisp one.
        drawRoundRect(accent.copy(alpha = 0.18f), Offset(0f, y - glow), Size(fw, th + glow * 2f), CornerRadius((th + glow * 2f) / 2f))
        drawRoundRect(accent.copy(alpha = 0.28f), Offset(0f, y - glow / 2f), Size(fw, th + glow), CornerRadius((th + glow) / 2f))
    }
    drawRoundRect(accent, Offset(0f, y), Size(fw, th), CornerRadius(th / 2f))
}

/** Breathing Glow: a plain fill whose halo swells in and out on a slow cycle. */
private fun DrawScope.breathingGlow(t: Double, p: Float, accent: Color, track: Color) {
    val breath = (0.5 + 0.5 * sin(t * 1.6)).toFloat()
    capsule(p, accent, track, thickness = 1.0f, glow = 3f + 9f * breath)
}

/** Traveling sine wave whose phase scrolls with t; played portion re-stroked bright. */
private fun DrawScope.wave(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val phase = t * 3.4
    val wavelength = max(26.0, (w / 12f).toDouble())
    val k = 2 * PI / wavelength
    val curve = Path().apply {
        moveTo(0f, mid)
        var x = 0f
        while (x <= w) {
            val yy = mid - (sin(x * k + phase)).toFloat() * (h * 0.30f)
            lineTo(x, yy)
            x += 2f
        }
    }
    drawPath(curve, track, style = Stroke(width = 3f))
    clipRect(right = max(0.1f, w * p)) {
        drawPath(curve, accent, style = Stroke(width = 3.5f))
    }
}

/** Hospital-monitor heartbeat sweep over a two-tone baseline. */
private fun DrawScope.heartbeat(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val amp = h * 0.40f
    drawLine(track, Offset(0f, mid), Offset(w, mid), strokeWidth = 2.5f)
    clipRect(right = max(0.1f, w * p)) {
        drawLine(accent.copy(alpha = 0.5f), Offset(0f, mid), Offset(w * p, mid), strokeWidth = 2.5f)
    }
    val sx = ((t * 0.45) % 1.0).toFloat() * w
    val spike = Path().apply {
        moveTo(max(0f, sx - 42f), mid)
        listOf(
            -18f to 0f, -10f to amp * 0.2f, -4f to -amp, 2f to amp * 0.5f, 8f to 0f, 42f to 0f,
        ).forEach { (dx, dy) -> lineTo(sx + dx, mid + dy) }
    }
    drawPath(spike, accent, style = Stroke(width = 3f))
    drawCircle(Color.White, radius = 3f, center = Offset(sx, mid))
}

/** Concentric rings emanating from the playhead. */
private fun DrawScope.ripple(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val th = max(4f, h * 0.34f)
    val y = (h - th) / 2f
    drawRoundRect(track, Offset(0f, y), Size(w, th), CornerRadius(th / 2f))
    drawRoundRect(accent, Offset(0f, y), Size(max(0f, w * p), th), CornerRadius(th / 2f))
    val cx = w * p
    val maxR = h * 1.7f
    val rings = 3
    for (kk in 0 until rings) {
        val frac = ((t * 0.8 + kk.toDouble() / rings) % 1.0).toFloat()
        val r = frac * maxR
        drawCircle(accent.copy(alpha = (1 - frac) * 0.6f), radius = r, center = Offset(cx, mid), style = Stroke(width = 2f))
    }
    drawCircle(Color.White, radius = 3.5f, center = Offset(cx, mid))
}

/** Row of beads, played side solid accent, with a brightening wet edge. */
private fun DrawScope.beads(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val count = max(8, (w / 16f).toInt())
    val spacing = w / count
    val r = min(h, spacing) * 0.24f
    val hx = ((t * 0.5) % 1.0).toFloat() * max(1f, w * p)
    for (i in 0 until count) {
        val cx = spacing * (i + 0.5f)
        val played = cx <= w * p
        val boost = if (played) max(0f, 1 - abs(cx - hx) / 36f) else 0f
        val rad = r * (if (played) 1.0f + 0.5f * boost else 0.7f)
        drawCircle(if (played) accent else track, radius = rad, center = Offset(cx, mid))
    }
}

/** VU bars that bounce, each with its own frequency/phase. */
private fun DrawScope.equalizer(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val count = max(10, (w / 12f).toInt())
    val spacing = w / count
    val bw = spacing * 0.5f
    for (i in 0 until count) {
        val cx = spacing * (i + 0.5f)
        val played = cx <= w * p
        val freq = 3.0 + (i % 5) * 0.8
        val phase = i * 0.9
        val base = if (played) 0.35f else 0.18f
        val amp = if (played) 0.55f else 0.12f
        val bh = h * (base + amp * (0.5f + 0.5f * sin(t * freq + phase).toFloat()))
        drawRoundRect(
            if (played) accent else track,
            Offset(cx - bw / 2f, (h - bh) / 2f),
            Size(bw, bh),
            CornerRadius(bw / 2f),
        )
    }
}

/** Comet (and Neon, louder): two-tone track with a glowing head that leaves a fading trail. */
private fun DrawScope.comet(t: Double, p: Float, accent: Color, track: Color, neon: Boolean) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val th = if (neon) max(5f, h * 0.4f) else max(4f, h * 0.28f)
    val y = (h - th) / 2f
    drawRoundRect(track, Offset(0f, y), Size(w, th), CornerRadius(th / 2f))
    val headX = w * p
    if (neon) {
        drawRoundRect(accent.copy(alpha = 0.35f), Offset(0f, y - 4f), Size(headX, th + 8f), CornerRadius((th + 8f) / 2f))
    }
    drawRoundRect(accent, Offset(0f, y), Size(headX, th), CornerRadius(th / 2f))
    val n = 6
    for (kk in 0 until n) {
        val frac = kk.toFloat() / n
        val x = headX - frac * 36f
        if (x <= 0f) continue
        val r = (1 - frac) * (h * 0.22f)
        drawCircle(accent.copy(alpha = (1 - frac) * 0.5f), radius = r, center = Offset(x, mid))
    }
    val pulse = (0.85 + 0.15 * sin(t * 4)).toFloat()
    val hr = h * 0.32f * pulse
    drawCircle(accent.copy(alpha = 0.85f), radius = hr, center = Offset(headX, mid))
    drawCircle(Color.White.copy(alpha = 0.95f), radius = hr * 0.6f, center = Offset(headX, mid))
}

/** Gradient fill with a bright sheen that sweeps across the played region and wraps. */
private fun DrawScope.gradientSweep(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val th = max(5f, h * 0.42f)
    val y = (h - th) / 2f
    drawRoundRect(track, Offset(0f, y), Size(w, th), CornerRadius(th / 2f))
    val fw = max(0.1f, w * p)
    clipRect(right = fw, top = y, bottom = y + th) {
        drawRoundRect(accent.copy(alpha = 0.75f), Offset(0f, y), Size(fw, th), CornerRadius(th / 2f))
        val band = fw + 70f
        val cx = ((t * 130) % band).toFloat()
        drawRoundRect(Color.White.copy(alpha = 0.35f), Offset(cx - 22f, y), Size(44f, th), CornerRadius(th / 2f))
    }
}

/** Liquid: a thick vessel filled to the playhead with a sloshing surface from two summed sines. */
private fun DrawScope.liquid(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val th = max(8f, h * 0.72f)
    val top = (h - th) / 2f
    drawRoundRect(track, Offset(0f, top), Size(w, th), CornerRadius(th / 2f))
    val fw = max(0.1f, w * p)
    clipRect(right = fw, top = top, bottom = top + th) {
        val baseY = top + th * 0.2f
        val path = Path().apply {
            moveTo(0f, top + th)
            var x = 0f
            while (x <= fw) {
                val yy = baseY + (sin(x * 0.05 + t * 2.2)).toFloat() * 2.6f + (sin(x * 0.12 - t * 1.6)).toFloat() * 1.8f
                lineTo(x, yy)
                x += 3f
            }
            lineTo(fw, top + th)
            close()
        }
        drawPath(path, accent)
    }
}

/** Runner: contiguous lit segments with a glowing highlight chasing along the played region. */
private fun DrawScope.runner(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val count = max(12, (w / 20f).toInt())
    val spacing = w / count
    val bw = spacing * 0.7f
    val bh = max(5f, h * 0.42f)
    val y = (h - bh) / 2f
    val hx = ((t * 0.6) % 1.0).toFloat() * max(1f, w * p)
    for (i in 0 until count) {
        val cx = spacing * (i + 0.5f)
        val played = cx <= w * p
        val boost = if (played) max(0f, 1 - abs(cx - hx) / 40f) else 0f
        if (boost > 0f) {
            drawRoundRect(accent.copy(alpha = boost * 0.5f), Offset(cx - bw / 2f - 3f, y - 3f), Size(bw + 6f, bh + 6f), CornerRadius(bh / 2f))
        }
        drawRoundRect(if (played) accent else track, Offset(cx - bw / 2f, y), Size(bw, bh), CornerRadius(bh / 2f))
    }
}

/** Spectrum: thin symmetric ticks about the centre line, each gently breathing. */
private fun DrawScope.spectrum(t: Double, p: Float, accent: Color, track: Color) {
    val w = size.width
    val h = size.height
    val mid = h / 2f
    val count = max(16, (w / 10f).toInt())
    val spacing = w / count
    val tw = max(1.5f, spacing * 0.3f)
    for (i in 0 until count) {
        val cx = spacing * (i + 0.5f)
        val played = cx <= w * p
        val env = if (played) 0.92f else 0.4f
        val mod = (0.7 + 0.3 * sin(t * 4 + i * 0.5)).toFloat()
        val th = h * env * mod
        drawRoundRect(
            if (played) accent else track,
            Offset(cx - tw / 2f, mid - th / 2f),
            Size(tw, th),
            CornerRadius(tw / 2f),
        )
    }
}
