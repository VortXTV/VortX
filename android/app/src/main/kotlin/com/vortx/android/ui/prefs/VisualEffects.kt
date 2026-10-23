package com.vortx.android.ui.prefs

import android.content.Context
import android.content.SharedPreferences
import android.content.res.Configuration
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import com.vortx.android.player.PerformanceMode

/**
 * The viewer's effects choices for the TV interface (Settings > Effects and performance), the Android twin
 * of Apple `VisualEffects` on the same keys and values.
 *
 * Every control stores "auto" or an explicit choice. Auto follows Performance on a TV: Reduced picks the
 * light option, Auto/Full on a capable box keeps the rich one. A phone keeps its effects unless they are
 * switched off explicitly. Choices stay on this device and are not synced, since a weak box that needs
 * still backdrops must not switch them off on a 4K TV elsewhere.
 */
object VisualEffects {
    enum class Backdrop(val storageValue: String) {
        /** The focused title's art fills the band and crossfades (with its slow pan) as focus moves. */
        ANIMATED("animated"),
        /** The art still follows focus but swaps without a crossfade or pan. */
        STILL("still"),
        /** No focus art; only the title details change. */
        OFF("off"),
    }

    data class State(val backdrop: Backdrop, val glass: Boolean, val motion: Boolean, val hdArtworkOnly: Boolean)

    const val KEY_BACKDROP = "vortx.effects.backdrop"
    const val KEY_GLASS = "vortx.effects.glass"
    const val KEY_MOTION = "vortx.effects.motion"
    const val KEY_ARTWORK = "vortx.effects.artwork"
    const val AUTO = "auto"
    private const val SETTINGS_FILE = "vortx_settings"
    internal val OBSERVED_KEYS = setOf(KEY_BACKDROP, KEY_GLASS, KEY_MOTION, KEY_ARTWORK, PerformanceMode.OVERRIDE_KEY)

    fun backdrop(stored: String?, reduced: Boolean): Backdrop =
        Backdrop.entries.firstOrNull { it.storageValue == stored } ?: if (reduced) Backdrop.STILL else Backdrop.ANIMATED

    /** Translucent glass and blurred art. Off renders the opaque surfaces the reduce-transparency proxy uses. */
    fun glass(stored: String?, reduced: Boolean): Boolean = toggle(stored, reduced)

    /** Interface animations: crossfades, the hero pan, focus scaling, and autoplaying hero trailers. */
    fun motion(stored: String?, reduced: Boolean): Boolean = toggle(stored, reduced)

    /** True when hero art is capped at 1080p, keeping much less image data decoded and resident. */
    fun hdArtworkOnly(stored: String?, reduced: Boolean): Boolean = when (stored) {
        "hd" -> true
        "full" -> false
        else -> reduced
    }

    private fun toggle(stored: String?, reduced: Boolean): Boolean = when (stored) {
        "on" -> true
        "off" -> false
        else -> !reduced
    }

    fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(SETTINGS_FILE, Context.MODE_PRIVATE)

    fun stored(context: Context, key: String): String = prefs(context).getString(key, AUTO) ?: AUTO

    fun set(context: Context, key: String, value: String) {
        prefs(context).edit().putString(key, value).apply()
    }

    /** Auto lightens the interface only on a TV, where Performance detects the weak boxes. */
    fun reducedForAuto(context: Context): Boolean {
        val tv = (context.resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_TELEVISION
        return tv && PerformanceMode.isReduced(context)
    }

    fun current(context: Context): State {
        val prefs = prefs(context)
        val reduced = reducedForAuto(context)
        return State(
            backdrop = backdrop(prefs.getString(KEY_BACKDROP, null), reduced),
            glass = glass(prefs.getString(KEY_GLASS, null), reduced),
            motion = motion(prefs.getString(KEY_MOTION, null), reduced),
            hdArtworkOnly = hdArtworkOnly(prefs.getString(KEY_ARTWORK, null), reduced),
        )
    }
}

/** The effects for this composition, provided once by `VortXTheme` so the many glass surfaces and
 *  motion checks share one preference listener. */
val LocalVisualEffects = compositionLocalOf<VisualEffects.State?> { null }

/** The provided effects, or (outside `VortXTheme`) a freshly observed copy. */
@Composable
fun currentVisualEffects(): VisualEffects.State = LocalVisualEffects.current ?: rememberVisualEffects()

/** The current effects, recomposing the moment Settings changes one (or Performance moves Auto). */
@Composable
fun rememberVisualEffects(): VisualEffects.State {
    val context = LocalContext.current.applicationContext
    val prefs = remember(context) { VisualEffects.prefs(context) }
    var state by remember(context) { mutableStateOf(VisualEffects.current(context)) }
    DisposableEffect(prefs) {
        val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == null || key in VisualEffects.OBSERVED_KEYS) state = VisualEffects.current(context)
        }
        prefs.registerOnSharedPreferenceChangeListener(listener)
        onDispose { prefs.unregisterOnSharedPreferenceChangeListener(listener) }
    }
    return state
}
