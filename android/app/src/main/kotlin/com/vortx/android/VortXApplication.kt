package com.vortx.android

import android.app.Application
import android.util.Log
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.disk.DiskCache
import coil3.memory.MemoryCache
import coil3.request.crossfade
import okio.Path.Companion.toOkioPath
import com.vortx.android.data.AuthRepository
import com.vortx.android.data.CatalogRepository
import com.vortx.android.data.PreviewAuthRepository
import com.vortx.android.data.PreviewCatalogRepository
import com.vortx.android.engine.EngineStremioRepository
import com.vortx.android.mediaserver.MediaServerRepository
import com.vortx.android.profile.ProfileStore

/// Owns the ONE [EngineStremioRepository] instance for the process's lifetime.
///
/// This matters for engine lifecycle correctness (ANDROID-PLAN.md S03: "init once at app start...
/// safe against double-init"): [MainActivity] does not construct the engine repository itself,
/// because an `Activity` can be torn down and recreated WITHIN THE SAME PROCESS (a config change
/// `MainActivity`'s manifest entry doesn't cover -- e.g. a system locale/night-mode change, or "Don't
/// keep activities" on some OEM skins) without the process (and so the JVM statics backing
/// [com.vortx.android.engine.StremioCoreNative]) ever restarting. If each `onCreate` built its own
/// `EngineStremioRepository`, the process-wide [com.vortx.android.engine.StremioCoreNative] object's
/// `initialized` guard would make every [com.vortx.android.engine.StremioCoreNative.init] after the
/// first return early WITHOUT re-registering the caller's listener -- so only the FIRST repository's
/// event listener is ever wired to native, and every subsequent Activity instance would hold a
/// repository whose engine event flow silently never fires again. (The native `nativeInit` itself does
/// not orphan a re-init: reached a second time it REPLACES the stored listener global ref,
/// last-writer-wins, and its runtime build is idempotent -- but the Kotlin-side guard means native
/// never even sees the second call.) Building it once here, keyed to [Application] (which really does
/// live for the process), makes that impossible: every `MainActivity.onCreate` reads the SAME
/// instance, whether it's the first launch or the fifth recreation.
///
/// A genuine process death (the OS reclaiming the whole app in the background) restarts this class
/// from scratch in a fresh process, which is the correct/expected reset: [EngineStremioRepository]
/// re-inits the native engine, which re-hydrates its own persisted state from disk, so Home/Continue
/// Watching/sign-in restore themselves with no extra code (see `EngineStremioRepository.start`).
class VortXApplication : Application(), SingletonImageLoader.Factory {

    /// Null only if native init genuinely failed (missing/incompatible `libstremiox_core.so`, an
    /// engine-side throw). Built once, lazily, on first access (not `onCreate`) so a
    /// [android.content.ContentProvider] or test harness that never touches the engine never pays the
    /// native-load cost.
    private val engine: EngineStremioRepository? by lazy {
        runCatching { EngineStremioRepository(this) }
            .getOrElse { error ->
                Log.e(TAG, "Engine repository unavailable; app falls back to offline preview data", error)
                null
            }
    }

    private val fallbackCatalogRepository by lazy { PreviewCatalogRepository() }
    private val fallbackAuthRepository by lazy { PreviewAuthRepository() }

    /// Warm the media-server store from disk at process start (idempotent), so a Plex/Jellyfin/Emby server
    /// connected in a previous run is queryable for direct-play sources on the very first detail page WITHOUT
    /// the user opening Settings. Dormant + cheap when no server is connected (an empty prefs read); it never
    /// touches the network here. The settings screen calls the same idempotent init defensively.
    override fun onCreate() {
        super.onCreate()
        // Stand up the multi-profile core once, before anything touches the engine (the engine is built
        // lazily on first catalog/auth access, after this). ProfileStore.init hydrates the roster, heals
        // the owner singleton, and makes ProfileStore.shared/activeProfileId available to the source-pin
        // per-profile key and the switch-listener reload hook wired in EngineStremioRepository.
        runCatching { ProfileStore.init(this) }
            .onFailure { Log.w(TAG, "Profile store init failed; profiles stay at defaults", it) }
        runCatching { MediaServerRepository.init(this) }
            .onFailure { Log.w(TAG, "Media-server store init failed; the feature stays dormant", it) }
    }

    /// The one [CatalogRepository] the whole app shares. Falls back to the offline preview data (same
    /// fail-soft boundary [MainActivity] used to own directly) so a native-side problem degrades the
    /// UI instead of crashing it.
    val catalogRepository: CatalogRepository get() = engine ?: fallbackCatalogRepository

    /// The one [AuthRepository] the whole app shares -- the SAME underlying engine instance as
    /// [catalogRepository] when the engine is up (one repository class implements both contracts), so
    /// a sign-in immediately shows up in every catalog call that reads `ctx`-derived state.
    val authRepository: AuthRepository get() = engine ?: fallbackAuthRepository

    /// Coil3's app-wide [ImageLoader] (S03: real poster/backdrop art in [com.vortx.android.ui.
    /// components.PosterArt]). `crossfade(true)` matches DESIGN-SYSTEM.md's motion spec for image
    /// reveals; the memory cache is capped as a PERCENT of available RAM (not a flat byte count) so it
    /// scales sanely from a low-RAM Android TV stick to a flagship phone, and the disk cache is a
    /// bounded slice of free space under this app's own cache dir (OS-purgeable, matches the engine's
    /// own cacheDir choice in `EngineStremioRepository.start`). The OkHttp network fetcher
    /// (`coil-network-okhttp`) needs no manual registration -- Coil3 wires it in automatically once the
    /// dependency is on the classpath.
    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .crossfade(true)
            .memoryCache {
                MemoryCache.Builder()
                    .maxSizePercent(context, 0.25)
                    .build()
            }
            .diskCache {
                DiskCache.Builder()
                    .directory(cacheDir.resolve("image_cache").toOkioPath())
                    .maxSizePercent(0.02)
                    .build()
            }
            .build()

    private companion object {
        const val TAG = "VortXApplication"
    }
}
