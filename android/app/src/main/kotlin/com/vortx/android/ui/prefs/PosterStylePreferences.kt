package com.vortx.android.ui.prefs

import android.content.Context
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.vortx.android.profile.ProfileStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Poster-card presentation preferences (width / corner-radius / landscape / hide-labels), the Kotlin port of
 * the poster-style half of Apple `app/SourcesShared/CatalogPreferences.swift` (`CatalogPrefsStore`). The
 * catalog cards + rails read these so a change in the Poster Style screen re-lays out live.
 *
 * Persisted on Apple's EXACT flat keys (`stremiox.catalog.posterWidthPreset` / `posterRadiusPreset` /
 * `landscapeCards` / `hidePosterLabels`), byte-identical, so the values ride the same cross-platform
 * settings carriage. These are presentation preferences, not credentials, so they live in the shared
 * [android.content.SharedPreferences] file the rest of the flat settings use.
 *
 * ANDROID DIVERGENCE (documented): `landscapeCards` defaults to FALSE here, where Apple's absent-key default
 * is true. Android has always shipped the portrait 2:3 catalog card; defaulting the toggle off keeps that
 * stable look and lets a user opt into the cinematic 16:9 landscape card, rather than silently re-laying out
 * every rail on first launch. An explicit value set on any platform still syncs across on the same key.
 */
object PosterStylePreferences {

    const val WIDTH_KEY = "stremiox.catalog.posterWidthPreset"
    const val RADIUS_KEY = "stremiox.catalog.posterRadiusPreset"
    const val LANDSCAPE_KEY = "stremiox.catalog.landscapeCards"
    const val HIDE_LABELS_KEY = "stremiox.catalog.hidePosterLabels"

    /**
     * Poster-card WIDTH presets. [compactWidth] is the phone (compact width class) point width, matching
     * Apple `PosterWidthPreset.compactWidth`; [balanced][BALANCED] is the shipping default. The wire name is
     * the Apple rawValue so a synced value maps across platforms.
     */
    enum class WidthPreset(val wire: String, val label: String, val compactWidth: Dp) {
        COMPACT("compact", "Compact", 110.dp),
        DENSE("dense", "Dense", 130.dp),
        STANDARD("standard", "Standard", 148.dp),
        BALANCED("balanced", "Balanced", 168.dp),
        COMFORT("comfort", "Comfort", 186.dp),
        LARGE("large", "Large", 200.dp);

        companion object {
            val DEFAULT = BALANCED
            fun fromWire(raw: String?): WidthPreset = entries.firstOrNull { it.wire == raw } ?: DEFAULT
        }
    }

    /** Poster-card CORNER RADIUS presets. [ROUNDED] (16dp = the card radius) is the shipping default. */
    enum class RadiusPreset(val wire: String, val label: String, val radius: Dp) {
        SHARP("sharp", "Sharp", 0.dp),
        SUBTLE("subtle", "Subtle", 6.dp),
        CLASSIC("classic", "Classic", 10.dp),
        ROUNDED("rounded", "Rounded", 16.dp),
        PILL("pill", "Pill", 28.dp);

        companion object {
            val DEFAULT = ROUNDED
            fun fromWire(raw: String?): RadiusPreset = entries.firstOrNull { it.wire == raw } ?: DEFAULT
        }
    }

    data class State(
        val width: WidthPreset = WidthPreset.DEFAULT,
        val radius: RadiusPreset = RadiusPreset.DEFAULT,
        val landscape: Boolean = false,
        val hideLabels: Boolean = false,
    )

    @Volatile private var appContext: Context? = null
    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    /** Wire the process application context once and seed [state] from persisted values. Idempotent. */
    fun init(context: Context) {
        appContext = context.applicationContext
        _state.value = readState()
    }

    private fun prefs() = appContext?.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)

    private fun readState(): State {
        val p = prefs() ?: return State()
        return State(
            width = WidthPreset.fromWire(p.getString(WIDTH_KEY, null)),
            radius = RadiusPreset.fromWire(p.getString(RADIUS_KEY, null)),
            landscape = p.getBoolean(LANDSCAPE_KEY, false),
            hideLabels = p.getBoolean(HIDE_LABELS_KEY, false),
        )
    }

    fun setWidth(preset: WidthPreset) = persist { putString(WIDTH_KEY, preset.wire) }.also {
        _state.value = _state.value.copy(width = preset)
    }

    fun setRadius(preset: RadiusPreset) = persist { putString(RADIUS_KEY, preset.wire) }.also {
        _state.value = _state.value.copy(radius = preset)
    }

    fun setLandscape(value: Boolean) = persist { putBoolean(LANDSCAPE_KEY, value) }.also {
        _state.value = _state.value.copy(landscape = value)
    }

    fun setHideLabels(value: Boolean) = persist { putBoolean(HIDE_LABELS_KEY, value) }.also {
        _state.value = _state.value.copy(hideLabels = value)
    }

    private inline fun persist(edit: android.content.SharedPreferences.Editor.() -> Unit) {
        prefs()?.edit()?.apply { edit(); apply() }
    }
}
