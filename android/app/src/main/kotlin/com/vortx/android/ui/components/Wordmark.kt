package com.vortx.android.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.vortx.android.ui.theme.VortXTheme

/// The VortX mark (DESIGN-SYSTEM.md §2 "The mark"): two woven ribbons crossing to form an X, plus a
/// cream center dot. Geometry ported verbatim from `res/drawable/ic_vortx_mark.xml`'s 108x108 viewport
/// (see that file's header comment for the original coordinate derivation) rather than re-derived, so
/// the app-icon/splash mark and this in-header Compose mark agree pixel-for-pixel on shape.
///
/// Two color modes:
///  - [fixedBrand] = true (the default) draws the fixed brand gold gradient — for the splash/header
///    lockups that must NOT recolor with the live accent theme (S01 handoff: "splash + app icon keep
///    the fixed brand gold").
///  - [fixedBrand] = false recolors the front ribbon to the live [VortXTheme] accent (the header mark
///    inside the app chrome, which "may recolor to the live accent" per the same handoff note).
@Composable
fun VortXMark(modifier: Modifier = Modifier, size: androidx.compose.ui.unit.Dp = 28.dp, fixedBrand: Boolean = true) {
    val accent = VortXTheme.colors.accent
    val accentBright = VortXTheme.colors.accentBright
    val frontColors = if (fixedBrand) {
        listOf(Color(0xFFFBBF24), Color(0xFFF59E0B), Color(0xFFD97706))
    } else {
        listOf(accentBright, accentBright, accent)
    }
    val backColors = listOf(Color(0xFFB45309), Color(0xFF7C2D12))
    val dotColor = Color(0xFFFDF6E3)

    Canvas(modifier = modifier.size(size)) {
        // Viewport is 108x108 in the source vector; scale uniformly to this composable's box.
        val viewport = 108f
        val scale = kotlin.math.min(this.size.width, this.size.height) / viewport
        val strokeWidth = 12.5f * scale
        fun p(x: Float, y: Float) = Offset(x * scale, y * scale)

        // Back ribbon: the "\" diagonal, drawn first so the front ribbon crosses over it.
        val back = androidx.compose.ui.graphics.Path().apply {
            moveTo(p(29.9f, 28.2f).x, p(29.9f, 28.2f).y)
            cubicTo(
                p(49.0f, 42.4f).x, p(49.0f, 42.4f).y,
                p(56.5f, 65.6f).x, p(56.5f, 65.6f).y,
                p(75.6f, 79.8f).x, p(75.6f, 79.8f).y,
            )
        }
        drawPath(
            path = back,
            brush = Brush.verticalGradient(backColors, startY = p(52.7f, 20f).y, endY = p(52.7f, 88f).y),
            style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
        )

        // Front ribbon: the "/" diagonal, drawn second so it crosses over the back ribbon.
        val front = androidx.compose.ui.graphics.Path().apply {
            moveTo(p(75.6f, 28.2f).x, p(75.6f, 28.2f).y)
            cubicTo(
                p(56.5f, 42.4f).x, p(56.5f, 42.4f).y,
                p(49.0f, 65.6f).x, p(49.0f, 65.6f).y,
                p(29.9f, 79.8f).x, p(29.9f, 79.8f).y,
            )
        }
        drawPath(
            path = front,
            brush = Brush.verticalGradient(frontColors, startY = p(52.7f, 20f).y, endY = p(52.7f, 88f).y),
            style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
        )

        // Cream center dot.
        drawCircle(color = dotColor, radius = 4.6f * scale, center = p(52.7f, 54f))
    }
}

/// "Vort" in the serif face + [VortXMark] standing in for the "X" (DESIGN-SYSTEM.md §2 "Wordmark") —
/// the editorial signature the tvOS/iOS apps lead Home with. The mark recolors to the live accent
/// ([VortXMark]'s `fixedBrand = false`) so it always matches whatever accent theme is active, exactly
/// like the header mark on Apple.
@Composable
fun Wordmark(modifier: Modifier = Modifier) {
    Row(modifier = modifier, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Text(
            text = "Vort",
            style = VortXTheme.type.screenTitle.copy(fontWeight = FontWeight.Bold),
        )
        VortXMark(size = 22.dp, fixedBrand = false)
    }
}
