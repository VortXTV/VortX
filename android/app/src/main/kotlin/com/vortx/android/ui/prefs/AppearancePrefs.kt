package com.vortx.android.ui.prefs

import android.content.Context
import com.vortx.android.profile.ProfileStore
import com.vortx.android.profile.UserProfile
import com.vortx.android.ui.theme.VortXAccents
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlin.math.round

/**
 * The active profile's appearance, mirrored into the same flat keys Apple uses.
 *
 * [ProfileStore] remains the profile and sync source of truth. Writes update its active immutable
 * profile, which republishes `activeProfile` and repaints the shells through the theme seam. The
 * flat keys preserve the shared cross-platform vocabulary and settings-backup behavior.
 */
class AppearancePrefs(context: Context) {
    data class State(
        val accentId: String,
        val oled: Boolean,
        val textScale: Double,
    )

    private val prefs =
        context.applicationContext.getSharedPreferences(ProfileStore.PREFS_FILE, Context.MODE_PRIVATE)
    private val _state =
        MutableStateFlow(ProfileStore.sharedOrNull()?.active?.toAppearanceState() ?: readFlatState())
    val state = _state.asStateFlow()

    fun applyProfile(profile: UserProfile?) {
        if (profile == null) return
        persist(profile.toAppearanceState())
    }

    fun setAccent(id: String) {
        update(_state.value.copy(accentId = normalizeAppearanceAccentId(id)))
    }

    fun setOled(enabled: Boolean) {
        update(_state.value.copy(oled = enabled))
    }

    fun setTextScale(value: Double) {
        if (!value.isFinite()) return
        update(_state.value.copy(textScale = normalizeAppearanceTextScale(value)))
    }

    private fun update(requested: State) {
        val next = requested.normalized()
        persist(next)
        val store = ProfileStore.sharedOrNull() ?: return
        val active = store.active ?: return
        val updated = active.withAppearance(next)
        if (updated != active) store.update(updated)
    }

    private fun persist(next: State) {
        prefs.edit()
            .putString(ACCENT_KEY, next.accentId)
            .putBoolean(OLED_KEY, next.oled)
            .putFloat(TEXT_SCALE_KEY, next.textScale.toFloat())
            .apply()
        _state.value = next
    }

    private fun readFlatState() = State(
        accentId = normalizeAppearanceAccentId(
            prefs.getString(ACCENT_KEY, VortXAccents.default.id) ?: VortXAccents.default.id,
        ),
        oled = prefs.getBoolean(OLED_KEY, false),
        textScale = normalizeAppearanceTextScale(
            prefs.getFloat(TEXT_SCALE_KEY, TEXT_SCALE_DEFAULT.toFloat()).toDouble(),
        ),
    )

    private fun UserProfile.toAppearanceState() = State(
        accentId = normalizeAppearanceAccentId(accentID),
        oled = oled,
        textScale = normalizeAppearanceTextScale(textScale),
    )

    private fun State.normalized() = State(
        accentId = normalizeAppearanceAccentId(accentId),
        oled = oled,
        textScale = normalizeAppearanceTextScale(textScale),
    )

    companion object {
        const val ACCENT_KEY = "stremiox.theme.accent"
        const val OLED_KEY = "stremiox.theme.oled"
        const val TEXT_SCALE_KEY = "stremiox.theme.textScale"

        const val TEXT_SCALE_MIN = 0.80
        const val TEXT_SCALE_MAX = 1.40
        const val TEXT_SCALE_DEFAULT = 1.0
        const val TEXT_SCALE_STEP = 0.05
    }
}

/** Only curated cross-platform accents persist. Material You remains a gallery preview. */
internal fun normalizeAppearanceAccentId(id: String): String = VortXAccents.byId(id).id

internal fun normalizeAppearanceTextScale(value: Double): Double {
    if (!value.isFinite()) return AppearancePrefs.TEXT_SCALE_DEFAULT
    return round(
        value.coerceIn(AppearancePrefs.TEXT_SCALE_MIN, AppearancePrefs.TEXT_SCALE_MAX) * 100.0,
    ) / 100.0
}

internal fun UserProfile.withAppearance(state: AppearancePrefs.State): UserProfile = copy(
    accentID = normalizeAppearanceAccentId(state.accentId),
    oled = state.oled,
    textScale = normalizeAppearanceTextScale(state.textScale),
)
