package com.vortx.android.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.vortx.android.ratings.RatingsFormat
import com.vortx.android.ui.theme.VortXTheme
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * One score as the rating service's mark beside its value ("[IMDb] 8.6", "[tomato] 96%"). Metacritic is its
 * own colour-coded square with the number inside, the way Metacritic prints it. Shared by the card plate, the
 * detail strips and the episode cards so every surface draws a score the same way. Mirrors Apple `RatingScore`.
 */
@Composable
fun RatingScore(token: RatingsFormat.Token, textSize: Int = 10, modifier: Modifier = Modifier) {
    val markHeight = (textSize * 1.15f).dp
    if (token.kind == RatingsFormat.Kind.METACRITIC) {
        MetascoreSquare(token.value, token.score, markHeight, modifier)
        return
    }
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy((textSize * 0.32f).dp),
    ) {
        RatingLogo(token.kind, token.score, markHeight)
        Text(
            text = token.value,
            maxLines = 1,
            style = TextStyle(
                color = VortXTheme.colors.textPrimary,
                fontSize = with(LocalDensity.current) { (textSize * 1.08f).dp.toSp() },
                fontWeight = FontWeight.SemiBold,
                fontFeatureSettings = "tnum",
            ),
        )
    }
}

/**
 * The rating services' marks, drawn from their shapes and colours: crisp at any size with no image assets.
 * Rotten Tomatoes and the Popcornmeter turn green below 60, as the services show them. Mirrors Apple `RatingLogo`.
 */
@Composable
fun RatingLogo(kind: RatingsFormat.Kind, score: Double, height: Dp) {
    when (kind) {
        RatingsFormat.Kind.IMDB ->
            Wordmark("IMDb", SolidColor(RatingMarkColors.imdbYellow),
                Color.Black, height, aspect = 2.0f, corner = 0.2f, scale = 0.66f)
        RatingsFormat.Kind.TMDB ->
            Wordmark("TMDB", Brush.horizontalGradient(listOf(RatingMarkColors.tmdbGreen, RatingMarkColors.tmdbBlue)),
                RatingMarkColors.tmdbNavy, height, aspect = 2.3f, corner = 0.5f, scale = 0.58f)
        RatingsFormat.Kind.MY_ANIME_LIST ->
            Wordmark("MAL", SolidColor(RatingMarkColors.malBlue),
                Color.White, height, aspect = 1.9f, corner = 0.2f, scale = 0.62f)
        RatingsFormat.Kind.KITSU ->
            Wordmark("KITSU", SolidColor(RatingMarkColors.kitsuCoral),
                Color.White, height, aspect = 2.5f, corner = 0.2f, scale = 0.52f)
        RatingsFormat.Kind.SIMKL ->
            Wordmark("SIMKL", SolidColor(RatingMarkColors.simklInk),
                Color.White, height, aspect = 2.5f, corner = 0.2f, scale = 0.52f, edge = Color.White.copy(alpha = 0.45f))
        RatingsFormat.Kind.METACRITIC -> MetascoreSquare("", score, height)
        RatingsFormat.Kind.ROTTEN_TOMATOES ->
            Canvas(Modifier.size(height)) { if (score >= 60) drawTomato() else drawSplat() }
        RatingsFormat.Kind.POPCORN ->
            Canvas(Modifier.size(height)) { drawPopcorn(fresh = score >= 60) }
        RatingsFormat.Kind.LETTERBOXD ->
            Canvas(Modifier.width(height * 1.55f).height(height)) { drawLetterboxd() }
        RatingsFormat.Kind.TRAKT ->
            Canvas(Modifier.size(height)) { drawTrakt() }
    }
}

@Composable
private fun Wordmark(
    text: String,
    fill: Brush,
    ink: Color,
    height: Dp,
    aspect: Float,
    corner: Float,
    scale: Float,
    edge: Color? = null,
) {
    val shape = RoundedCornerShape(height * corner)
    Box(
        modifier = Modifier
            .width(height * aspect)
            .height(height)
            .clip(shape)
            .background(fill)
            .then(if (edge != null) Modifier.border(maxOf(1.dp, height * 0.06f), edge, shape) else Modifier),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text,
            maxLines = 1,
            style = TextStyle(
                color = ink,
                fontSize = with(LocalDensity.current) { (height * scale).toSp() },
                fontWeight = FontWeight.Black,
            ),
        )
    }
}

/** Metacritic's score square: green from 61, yellow from 40, red below, with the number inside. */
@Composable
private fun MetascoreSquare(value: String, score: Double, height: Dp, modifier: Modifier = Modifier) {
    val color = when {
        score >= 61 -> RatingMarkColors.metacriticGreen
        score >= 40 -> RatingMarkColors.metacriticYellow
        else -> RatingMarkColors.metacriticRed
    }
    Box(
        modifier = modifier
            .defaultMinSize(minWidth = height * 1.2f)
            .height(height)
            .clip(RoundedCornerShape(height * 0.22f))
            .background(color)
            .padding(horizontal = height * 0.2f),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = value,
            maxLines = 1,
            style = TextStyle(
                color = Color(0xFF0F0F0F),
                fontSize = with(LocalDensity.current) { (height * 0.66f).toSp() },
                fontWeight = FontWeight.ExtraBold,
                fontFeatureSettings = "tnum",
            ),
        )
    }
}

private object RatingMarkColors {
    val imdbYellow = Color(0xFFF5C518)
    val tmdbGreen = Color(0xFF90CEA1)
    val tmdbBlue = Color(0xFF01B4E4)
    val tmdbNavy = Color(0xFF0D253F)
    val malBlue = Color(0xFF2E51A2)
    val kitsuCoral = Color(0xFFF75239)
    val simklInk = Color(0xFF0B0F10)
    val tomatoRed = Color(0xFFFA320A)
    val tomatoLeaf = Color(0xFF00912D)
    val rottenGreen = Color(0xFF0AC855)
    val popcornCream = Color(0xFFFFF3D1)
    val letterboxdOrange = Color(0xFFFF8000)
    val letterboxdGreen = Color(0xFF00E054)
    val letterboxdBlue = Color(0xFF40BCF4)
    val traktRed = Color(0xFFED1C24)
    val metacriticGreen = Color(0xFF00CE7A)
    val metacriticYellow = Color(0xFFFFBD3F)
    val metacriticRed = Color(0xFFFF6874)
}

// The drawn marks, in unit coordinates scaled to the canvas so one path serves every size (Apple RatingMarkPaths).

private fun DrawScope.drawTomato() {
    val w = size.width
    val h = size.height
    drawOval(RatingMarkColors.tomatoRed, topLeft = Offset(w * 0.04f, h * 0.2f), size = Size(w * 0.92f, h * 0.78f))
    drawOval(Color.White.copy(alpha = 0.28f), topLeft = Offset(w * 0.2f, h * 0.32f), size = Size(w * 0.22f, h * 0.16f))
    drawPath(star(Offset(w * 0.5f, h * 0.22f), outer = w * 0.26f, inner = w * 0.1f, points = 5), RatingMarkColors.tomatoLeaf)
}

private fun DrawScope.drawSplat() {
    val w = size.width
    val h = size.height
    // Uneven lobes with deep notches between them, then two flung droplets: a splat, not a star.
    val radii = floatArrayOf(0.47f, 0.25f, 0.41f, 0.23f, 0.45f, 0.27f, 0.37f, 0.22f, 0.43f, 0.24f, 0.39f, 0.23f, 0.46f, 0.26f)
    fun point(index: Int, scale: Float = 1f): Offset {
        val angle = index.toDouble() / radii.size * 2 * PI - PI / 2 + 0.2
        val radius = radii[index % radii.size] * scale
        return Offset(w * 0.5f + (cos(angle) * w * radius).toFloat(), h * 0.52f + (sin(angle) * w * radius).toFloat())
    }
    val path = Path()
    val start = point(radii.size - 1)
    path.moveTo(start.x, start.y)
    // Even indices are lobe tips, odd ones the notches: each lobe bulges from notch to notch past its tip.
    for (tip in 0 until radii.size step 2) {
        val control = point(tip, scale = 1.25f)
        val end = point(tip + 1)
        path.cubicTo(control.x, control.y, control.x, control.y, end.x, end.y)
    }
    path.close()
    drawPath(path, RatingMarkColors.rottenGreen)
    drawCircle(RatingMarkColors.rottenGreen, radius = w * 0.06f, center = Offset(w * 0.9f, h * 0.18f))
    drawCircle(RatingMarkColors.rottenGreen, radius = w * 0.05f, center = Offset(w * 0.1f, h * 0.86f))
}

private fun DrawScope.drawPopcorn(fresh: Boolean) {
    val w = size.width
    val h = size.height
    val kernels = if (fresh) {
        listOf(0.3f to 0.34f, 0.5f to 0.26f, 0.7f to 0.34f, 0.4f to 0.18f, 0.6f to 0.18f)
    } else {
        listOf(0.36f to 0.34f, 0.62f to 0.32f)
    }
    for ((x, y) in kernels) {
        drawOval(RatingMarkColors.popcornCream, topLeft = Offset(w * (x - 0.15f), h * (y - 0.13f)), size = Size(w * 0.3f, h * 0.27f))
    }
    val bucket = Path().apply {
        moveTo(w * 0.14f, h * 0.4f)
        lineTo(w * 0.86f, h * 0.4f)
        lineTo(w * 0.72f, h * 0.98f)
        lineTo(w * 0.28f, h * 0.98f)
        close()
    }
    drawPath(bucket, if (fresh) RatingMarkColors.tomatoRed else RatingMarkColors.rottenGreen)
    clipPath(bucket) {
        // Two white stripes that taper with the bucket (0.72 wide at the rim, 0.44 at the base).
        for (top in listOf(0.38f, 0.62f)) {
            val bottom = 0.5f + (top - 0.5f) * 0.44f / 0.72f
            val stripe = Path().apply {
                moveTo(w * (top - 0.05f), h * 0.4f)
                lineTo(w * (top + 0.05f), h * 0.4f)
                lineTo(w * (bottom + 0.035f), h)
                lineTo(w * (bottom - 0.035f), h)
                close()
            }
            drawPath(stripe, Color.White)
        }
    }
}

private fun DrawScope.drawLetterboxd() {
    val h = size.height
    val radius = h * 0.33f
    drawCircle(RatingMarkColors.letterboxdOrange, radius = radius, center = Offset(h * 0.34f, h * 0.5f))
    drawCircle(RatingMarkColors.letterboxdBlue, radius = radius, center = Offset(h * 1.21f, h * 0.5f))
    drawCircle(RatingMarkColors.letterboxdGreen, radius = radius, center = Offset(h * 0.775f, h * 0.5f))
}

private fun DrawScope.drawTrakt() {
    val w = size.width
    val h = size.height
    drawCircle(RatingMarkColors.traktRed, radius = w * 0.5f, center = Offset(w * 0.5f, h * 0.5f))
    drawCircle(Color.White, radius = w * 0.33f, center = Offset(w * 0.5f, h * 0.5f), style = Stroke(width = w * 0.08f))
    val check = Path().apply {
        moveTo(w * 0.36f, h * 0.5f)
        lineTo(w * 0.47f, h * 0.61f)
        lineTo(w * 0.67f, h * 0.38f)
    }
    drawPath(check, Color.White, style = Stroke(width = w * 0.09f, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

private fun star(center: Offset, outer: Float, inner: Float, points: Int): Path {
    val path = Path()
    for (index in 0 until points * 2) {
        val radius = if (index % 2 == 0) outer else inner
        val angle = index.toDouble() / (points * 2) * 2 * PI - PI / 2
        val x = center.x + (cos(angle) * radius).toFloat()
        val y = center.y + (sin(angle) * radius).toFloat()
        if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
    path.close()
    return path
}
