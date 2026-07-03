package com.stremiox.android

import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.stremiox.android.data.CatalogRepository
import com.stremiox.android.data.PreviewCatalogRepository
import com.stremiox.android.engine.EngineStremioRepository
import com.stremiox.android.ui.StremioXApp

/// Android + Android TV entry point. The five-tab Compose shell in [StremioXApp] matches the iOS and
/// Apple TV structure. It now runs on the shared stremio-core engine (over JNI, the same engine the
/// iOS/tvOS apps use) via [EngineStremioRepository]; the libmpv player drops in behind the same seam.
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { StremioXApp(repo = engineRepository()) }
    }

    /// Build the real engine repository, backed by [com.stremiox.android.engine.StremioXCore] (native
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
