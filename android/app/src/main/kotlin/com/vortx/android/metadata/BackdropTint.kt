package com.vortx.android.metadata

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.request.allowHardware
import coil3.SingletonImageLoader
import coil3.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Dominant-color backdrop tint for the detail/hero band, the Kotlin port of Apple
 * `PosterImageLoader.averageColor`. CHEAP by construction: the backdrop is fetched at ~32px through the
 * SAME Coil loader the hero already showed (so it re-serves from cache), decoded software-only, and the
 * average is read from an 8x8 render (64 pixels), alpha-weighted so transparent regions never drag the tint
 * toward black. Returns null on any miss so a caller keeps its fixed-gradient fallback.
 *
 * Results are memoized per art URL (a tiny 3-float value, generously capped) so scrolling back to a detail
 * page re-paints its tint from memory.
 */
object BackdropTint {

    private const val TINT_SAMPLE_PX = 32
    private const val AVERAGE_SIDE = 8
    private const val CACHE_CAP = 300

    private val lock = Any()
    private val cache = LinkedHashMap<String, Color>()

    /** The alpha-weighted average color of the art at [url], for the hero/detail band tint, or null. */
    suspend fun averageColor(context: Context, url: String?): Color? {
        val clean = url?.takeIf { it.isNotBlank() } ?: return null
        synchronized(lock) { cache[clean] }?.let { return it }
        val tint = withContext(Dispatchers.IO) {
            runCatching {
                val request = ImageRequest.Builder(context)
                    .data(clean)
                    .size(TINT_SAMPLE_PX, TINT_SAMPLE_PX)
                    .allowHardware(false) // a hardware bitmap cannot be read back pixel-by-pixel below
                    .build()
                val result = SingletonImageLoader.get(context).execute(request)
                val image = (result as? SuccessResult)?.image ?: return@runCatching null
                averageOf(image.toBitmap())
            }.getOrNull()
        } ?: return null
        synchronized(lock) {
            if (cache.size >= CACHE_CAP) cache.entries.iterator().let { if (it.hasNext()) { it.next(); it.remove() } }
            cache[clean] = tint
        }
        return tint
    }

    /** Draw the (already tiny) bitmap into an 8x8 grid and average the 64 pixels, alpha-weighted. */
    private fun averageOf(source: Bitmap): Color? {
        val scaled = runCatching {
            Bitmap.createScaledBitmap(source, AVERAGE_SIDE, AVERAGE_SIDE, true)
        }.getOrNull() ?: return null
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var a = 0.0
        for (y in 0 until AVERAGE_SIDE) {
            for (x in 0 until AVERAGE_SIDE) {
                val pixel = scaled.getPixel(x, y)
                val alpha = (pixel ushr 24) and 0xFF
                if (alpha == 0) continue
                // Weight each channel by alpha so transparent regions don't drag the tint toward black.
                r += ((pixel ushr 16) and 0xFF) * alpha
                g += ((pixel ushr 8) and 0xFF) * alpha
                b += (pixel and 0xFF) * alpha
                a += alpha
            }
        }
        if (a <= 0.0) return null
        return Color(
            red = ((r / a) / 255.0).toFloat().coerceIn(0f, 1f),
            green = ((g / a) / 255.0).toFloat().coerceIn(0f, 1f),
            blue = ((b / a) / 255.0).toFloat().coerceIn(0f, 1f),
        )
    }
}

/**
 * The dominant tint of [url], resolved off-main via [BackdropTint] and returned as observable state; null
 * until it resolves (or on any miss), so the caller keeps its fixed-gradient fallback until then.
 */
@Composable
fun rememberBackdropTint(url: String?): State<Color?> {
    val context = LocalContext.current
    val tint = remember(url) { mutableStateOf<Color?>(null) }
    LaunchedEffect(url) {
        tint.value = BackdropTint.averageColor(context, url)
    }
    return tint
}
