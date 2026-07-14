package com.vortx.android

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.graphics.Color
import android.os.Bundle
import android.view.animation.AnticipateInterpolator
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.vortx.android.ui.StremioXApp
import com.vortx.android.ui.theme.isAnimatorScaleZero

/// Android + Android TV entry point. The five-tab Compose shell in [StremioXApp] matches the iOS and
/// Apple TV structure. It now runs on the shared stremio-core engine (over JNI, the same engine the
/// iOS/tvOS apps use) via [com.vortx.android.engine.EngineStremioRepository]; the libmpv player
/// drops in behind the same seam. The repository itself is owned by [VortXApplication] (constructed
/// once per process, not per Activity instance) -- see that class's doc comment for why that matters
/// (engine double-init / event-listener orphaning safety across Activity recreation).
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // installSplashScreen() must run before super.onCreate(): it installs the AndroidX
        // SplashScreen (Theme.VortX.Splash -- brand gold mark on warm obsidian, see themes.xml) for
        // the cold-start gap before Compose draws its first frame. Framework-owned on API 31+; the
        // compat library paints the same background+icon itself on 26-30, so minSdk 26 gets it
        // uniformly.
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)

        // Edge-to-edge is enforced app-wide (ANDROID-PLAN.md S01 scope; DESIGN-SYSTEM.md chrome
        // recedes behind content). StremioXTheme forces the dark scheme regardless of the system
        // setting (ui/theme/Theme.kt), so both system bars get light icons unconditionally instead of
        // the OS's light/dark auto-resolution, which would otherwise mismatch a light system theme.
        // The Compose shell consumes the resulting insets via Scaffold's contentPadding (StremioXApp).
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )

        // Reduced motion (Settings.Global.ANIMATOR_DURATION_SCALE == 0, the same system signal the
        // Android-native translation table in ANDROID-PLAN.md §0 calls out, now the one shared
        // ui/theme/Motion.kt utility every reduced-motion check in the app reads): skip the custom
        // fade-out and let the splash view disappear immediately instead of animating it off.
        if (!isAnimatorScaleZero()) {
            splashScreen.setOnExitAnimationListener { view ->
                ObjectAnimator.ofFloat(view.view, "alpha", 1f, 0f).apply {
                    duration = 220L
                    interpolator = AnticipateInterpolator()
                    addListener(object : AnimatorListenerAdapter() {
                        override fun onAnimationEnd(animation: Animator) = view.remove()
                    })
                    start()
                }
            }
        }

        // The engine repository lives on VortXApplication (constructed once per process), NOT built
        // here -- see VortXApplication's doc comment for why an Activity-scoped instance is unsafe.
        val app = application as VortXApplication
        setContent { StremioXApp(repo = app.catalogRepository, auth = app.authRepository) }
    }
}
