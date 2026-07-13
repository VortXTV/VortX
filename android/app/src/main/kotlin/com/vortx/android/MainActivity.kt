package com.vortx.android

import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.EngineStremioRepository
import com.vortx.android.ui.StremioXApp

/// Android + Android TV entry point. The five-tab Compose shell in [StremioXApp] matches the iOS and
/// Apple TV structure. It now runs on the shared stremio-core engine (over JNI, the same engine the
/// iOS/tvOS apps use) via [EngineStremioRepository]; the libmpv player drops in behind the same seam.
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // installSplashScreen() must run before super.onCreate(); it swaps the launch theme
        // (Theme.VortX.Starting) to the app theme (postSplashScreenTheme = Theme.VortX). When the user
        // has animations turned off (accessibility "remove animations" sets the animator duration scale
        // to 0), we skip the splash exit transition and remove it instantly instead of running any
        // fade/scale.
        val splashScreen = installSplashScreen()
        if (animationsDisabled()) {
            splashScreen.setOnExitAnimationListener { splashScreenViewProvider ->
                splashScreenViewProvider.remove()
            }
        }
        super.onCreate(savedInstanceState)
        setContent { StremioXApp(repo = engineRepository()) }
    }

    /// True when the OS has animations disabled (accessibility "remove animations", or Developer
    /// Options animator scale set to 0). Used to honor reduced-motion on the launch splash.
    private fun animationsDisabled(): Boolean =
        Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

    /// Build the real engine repository, backed by [com.vortx.android.engine.StremioCoreNative] (native
    /// lib load + engine init happen inside its constructor). This is the boundary where the native
    /// world can fail hard: a missing/incompatible `libstremiox_core.so` throws [UnsatisfiedLinkError]
    /// when the class loads, and engine init can throw. We keep it fail-soft so a native-side problem
    /// degrades to the offline preview data (the UI still renders) instead of crashing the whole app.
    private fun engineRepository(): CatalogRepository =
        runCatching { EngineStremioRepository(applicationContext) as CatalogRepository }
            .getOrElse { error ->
                Log.e(TAG, "Engine repository unavailable; falling back to preview data", error)
                PreviewCatalogRepository()
            }

    private companion object {
        const val TAG = "StremioXEngine"
    }
}
