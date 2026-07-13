package com.stremiox.android.ui.theme

import android.content.Context
import android.provider.Settings
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext

/// Motion spec (DESIGN-SYSTEM.md §2 "Radius / elevation / motion"). The CSS spring
/// `cubic-bezier(.2,.8,.2,1)` translated to Compose's [CubicBezierEasing] (same four control points).
/// Animate transform/opacity/shadow ONLY, never layout — every component built against this object
/// follows that rule.
object VortXMotion {
    val easing = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1f)

    /// `state change 180ms` — press/selection/hover-class transitions.
    const val STATE_MS = 180

    /// `hero/focus ~320ms` — poster lift/glow, hero cross-fade, screen-level focus moves.
    const val HERO_MS = 320

    /// `press = scale(.97)` — the one canonical press-down scale, used by every pressable component.
    const val PRESS_SCALE = 0.97f

    /// `pressed lift + scale(~1.03) + glow` for the PosterCard hover/focus state (§3 "Poster card").
    const val POSTER_FOCUS_SCALE = 1.03f

    fun <T> state(): AnimationSpec<T> = tween(durationMillis = STATE_MS, easing = easing)
    fun <T> hero(): AnimationSpec<T> = tween(durationMillis = HERO_MS, easing = easing)

    /// Reduced-motion-aware spec: collapses to an instant [snap] when the system's
    /// `Settings.Global.ANIMATOR_DURATION_SCALE` is 0 (the same signal `MainActivity.animationsReduced`
    /// reads for the splash exit — the Android-native analogue of Reduce Motion, per the translation
    /// table in ANDROID-PLAN.md §0), dropping the transform/opacity animation entirely rather than
    /// slowing it down.
    fun <T> stateAware(reducedMotion: Boolean): AnimationSpec<T> =
        if (reducedMotion) snap() else state()

    fun <T> heroAware(reducedMotion: Boolean): AnimationSpec<T> =
        if (reducedMotion) snap() else hero()
}

/// Reads `Settings.Global.ANIMATOR_DURATION_SCALE == 0`, the single shared utility every reduced-motion
/// check in the app (splash exit, component press/focus animations) should call instead of re-reading
/// the setting inline.
fun Context.isAnimatorScaleZero(): Boolean =
    Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

/// Composition-scoped reduced-motion flag, read once per composition from [isAnimatorScaleZero] and
/// exposed via [LocalReducedMotion] so components don't each need a [Context] lookup.
val LocalReducedMotion = staticCompositionLocalOf { false }

@Composable
fun rememberReducedMotion(): Boolean {
    val context = LocalContext.current
    return context.isAnimatorScaleZero()
}
