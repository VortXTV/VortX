package com.vortx.android.ui.tv

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.vortx.android.VortXApplication

/// Android TV (10-foot / D-pad) entry point. This is the activity the `LEANBACK_LAUNCHER` intent lands on
/// (see AndroidManifest.xml), kept DISTINCT from the phone [com.vortx.android.MainActivity] so the two
/// form factors can diverge in layout and focus model while sharing one process and one data path.
///
/// It shares everything below the presentation layer with the phone shell:
///   - the SAME process-wide [com.vortx.android.data.CatalogRepository] / [com.vortx.android.data.AuthRepository]
///     owned by [VortXApplication] (built once per process -- see that class's doc comment for why an
///     Activity-scoped engine instance is unsafe; a second Activity reading the same singleton is exactly
///     the intended path),
///   - the SAME [com.vortx.android.ui.viewmodel.HomeViewModel] / [com.vortx.android.ui.viewmodel.DetailViewModel]
///     (constructed via [com.vortx.android.ui.viewmodel.StremioXViewModelFactory] inside [TvApp]),
///   - the SAME [com.vortx.android.player.PlayerScreen] for playback.
///
/// The active profile (and its Kids content guard) is honored transparently: [VortXApplication.onCreate]
/// stands up `ProfileStore` before any Activity, and the reused ViewModels read the active profile the same
/// way the phone does (the source ranking's `isKids` gate lives inside [DetailViewModel], so it applies on
/// TV with no extra code). Splash + edge-to-edge mirror [com.vortx.android.MainActivity].
class TvActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Same cold-start splash contract as MainActivity: install before super.onCreate so the brand
        // gold mark on warm obsidian covers the gap before Compose's first frame (framework-owned on
        // API 31+, compat-drawn on 26-30). No custom exit animation here -- a TV has no touch-dismiss and
        // the default fade is fine at 10 feet.
        installSplashScreen()
        super.onCreate(savedInstanceState)

        val app = application as VortXApplication
        setContent { TvApp(repo = app.catalogRepository, auth = app.authRepository) }
    }
}
