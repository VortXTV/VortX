package com.vortx.android

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ObjectAnimator
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.animation.AnticipateInterpolator
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.vortx.android.deeplink.DeepLinkDeliveryState
import com.vortx.android.deeplink.VortXDeepLinkEvent
import com.vortx.android.player.PlayerPipBridge
import com.vortx.android.ui.VortXApp
import com.vortx.android.ui.prefs.AppLanguage
import com.vortx.android.ui.theme.isAnimatorScaleZero
import java.util.Locale
import java.util.UUID

/// Android + Android TV entry point. The five-tab Compose shell in [VortXApp] matches the iOS and
/// Apple TV structure. It now runs on the shared stremio-core engine (over JNI, the same engine the
/// iOS/tvOS apps use) via [com.vortx.android.engine.EngineStremioRepository]; the libmpv player
/// drops in behind the same seam. The repository itself is owned by [VortXApplication] (constructed
/// once per process, not per Activity instance) -- see that class's doc comment for why that matters
/// (engine double-init / event-listener orphaning safety across Activity recreation).
class MainActivity : ComponentActivity() {
    override fun attachBaseContext(base: Context) {
        val wrapped = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) base else {
            // WHY audit row 09: API 26-32 stored the override but did not apply it before Activity creation.
            val locale = AppLanguage.current(base)
                ?.takeIf { tag -> AppLanguage.supported.any { (supported, _) -> supported == tag } }
                ?.let(Locale::forLanguageTag)
            if (locale == null) base else base.createConfigurationContext(
                Configuration(base.resources.configuration).apply {
                    setLocale(locale)
                    setLayoutDirection(locale)
                },
            )
        }
        super.attachBaseContext(wrapped)
    }

    private var deepLinkEvent by mutableStateOf<VortXDeepLinkEvent?>(null)
    private var deepLinkSequence = 0L
    private var deepLinkDelivery = DeepLinkDeliveryState()

    override fun onCreate(savedInstanceState: Bundle?) {
        // installSplashScreen() must run before super.onCreate(): it installs the AndroidX
        // SplashScreen (Theme.VortX.Splash -- brand gold mark on warm obsidian, see themes.xml) for
        // the cold-start gap before Compose draws its first frame. Framework-owned on API 31+; the
        // compat library paints the same background+icon itself on 26-30, so minSdk 26 gets it
        // uniformly.
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        val restoredDeliveryId = savedInstanceState?.getString(STATE_DEEP_LINK_DELIVERY_ID)
        deepLinkDelivery = DeepLinkDeliveryState(
            restoredConsumedDeliveryId = restoredDeliveryId,
        )
        routeDeepLink(intent, restoredDeliveryId = restoredDeliveryId)

        // Edge-to-edge is enforced app-wide (ANDROID-PLAN.md S01 scope; DESIGN-SYSTEM.md chrome
        // recedes behind content). VortXTheme forces the dark scheme regardless of the system
        // setting (ui/theme/Theme.kt), so both system bars get light icons unconditionally instead of
        // the OS's light/dark auto-resolution, which would otherwise mismatch a light system theme.
        // The Compose shell consumes the resulting insets via Scaffold's contentPadding (VortXApp).
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
        setContent {
            VortXApp(
                repo = app.catalogRepository,
                auth = app.authRepository,
                // The VortX account + cross-device sync engine (nullable: sync is off the critical
                // path; a keystore failure hides the account row instead of blocking launch).
                syncManager = app.syncManager,
                deepLinkEvent = deepLinkEvent,
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        routeDeepLink(intent, forceNewDelivery = true)
    }

    private fun routeDeepLink(
        intent: Intent?,
        restoredDeliveryId: String? = null,
        forceNewDelivery: Boolean = false,
    ) {
        val deliveryId = deliveryId(intent, restoredDeliveryId, forceNewDelivery)
        if (deepLinkDelivery.isConsumed(deliveryId)) {
            clearDeepLinkData(intent)
            return
        }
        val target = deepLinkDelivery.consume(deliveryId, intent?.dataString) ?: return
        clearDeepLinkData(intent)
        deepLinkEvent = VortXDeepLinkEvent(target, ++deepLinkSequence)
    }

    private fun deliveryId(source: Intent?, restoredDeliveryId: String?, forceNew: Boolean): String {
        val retained = source?.getStringExtra(EXTRA_DEEP_LINK_DELIVERY_ID)
        if (!forceNew && restoredDeliveryId != null && retained == restoredDeliveryId) {
            return retained
        }
        return UUID.randomUUID().toString().also { source?.putExtra(EXTRA_DEEP_LINK_DELIVERY_ID, it) }
    }

    private fun clearDeepLinkData(source: Intent?) {
        source ?: return
        source.data = null
        setIntent(source)
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString(STATE_DEEP_LINK_DELIVERY_ID, deepLinkDelivery.consumedDeliveryId)
        super.onSaveInstanceState(outState)
    }

    /// Home press during playback -> Picture-in-Picture, on API 26-30 where the params-based
    /// auto-enter (S+) does not exist. The bridge holds the live player's "am I actually playing"
    /// probe and entry action ONLY while a player is composed, so this is inert on every other
    /// screen; on S+ it is a no-op entirely (auto-enter owns the transition there). This override
    /// is the one piece of PiP that must live on the Activity, because onUserLeaveHint has no
    /// listener API to reach it from a composable.
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        PlayerPipBridge.onUserLeaveHint()
    }

    private companion object {
        const val STATE_DEEP_LINK_DELIVERY_ID = "vortx.deepLinkDeliveryId"
        const val EXTRA_DEEP_LINK_DELIVERY_ID = "com.vortx.android.extra.DEEP_LINK_DELIVERY_ID"
    }
}
