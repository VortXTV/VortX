package com.vortx.android.engine

import android.content.Context
import android.util.Log
import com.vortx.android.sources.SourcePreferencesStore
import org.json.JSONObject
import java.io.File

/// The raw JNI surface to the OWN vortx-core IN-PROCESS STREAMING SERVER (the rqbit torrent
/// server inside `libvortx_ffi.so`, built from the engine branch's `vortx-core/crates/ffi` cdylib
/// with `--no-default-features --features jni,server`; see `android/app/src/main/jniLibs/README.md`
/// for the build step). The Android twin of the Apple embed lifecycle (`vortx_server_start` /
/// `port` / `base_url` / `stop` in `crates/ffi/src/server.rs`): iOS/tvOS cannot spawn the server
/// bin as a subprocess, and neither can Android, so both run it in-process and hand the player a
/// loopback URL. This is what makes a RAW torrent (no debrid key) actually play on Android.
///
/// The package + class are `com.vortx.android.engine.VortxServer` and the Rust exports in
/// `vortx-core/crates/ffi/src/jni_server.rs` are derived from that exact package + class
/// (`Java_com_vortx_android_engine_VortxServer_*`), so renaming either side breaks the dynamic
/// link. Do not rename without updating both sides together (the same rule as [VortxCore]).
///
/// Server HTTP contract (the same one the desktop node server speaks, so the URL shape is the
/// one the apps already know): base `http://127.0.0.1:PORT`, playback at
/// `GET /{infoHash}/{fileIdx}` (Range-capable; auto-creates the torrent on a bare GET),
/// `POST /{infoHash}/create`, `GET /{infoHash}/stats.json`, `GET /{infoHash}/remove`.
///
/// Threading: [nativeStart] and [nativeStop] block briefly (bind / graceful shutdown), so call
/// [startIfNeeded]/[stop] from a worker thread (the resolve path wraps them in Dispatchers.IO),
/// never the main thread. One call at a time per handle, serialized here by @Synchronized.
object VortxServer {

    private const val TAG = "VortxServer"

    /// The kill-switch flag key, in the app's flat `vortx.*` settings namespace (the same
    /// `vortx_settings` file every other streaming preference lives in, mirroring
    /// [VortxRankingShadow.FLAG_KEY]). DEFAULT ON: with the server absent a raw torrent could
    /// only ever throw, so serving it is a strict improvement; the flag exists so the lane can
    /// be killed remotely-by-settings without a build if the in-process server misbehaves.
    const val FLAG_KEY = "vortx.engine.torrentStreaming"

    /// The server data root, a subdir of the app CACHE dir: settings.json, the piece cache, and
    /// the port file live under here. Cache (not files) on purpose: the OS may reclaim it under
    /// storage pressure, and everything inside is re-creatable.
    private const val SERVER_HOME_DIR = "vortx-server"

    /// Sandbox self-bounds, the engine's own "Android-shaped config" (see the
    /// `jni_server.rs` round-trip test): a 128 MiB piece-cache cap + 35 peer connections keep
    /// disk and battery bounded on phones/TV sticks. Without an explicit cap the server's
    /// settings default is 2 GiB, sized for desktops.
    private const val CACHE_SIZE_BYTES = 134_217_728L
    private const val BT_MAX_CONNECTIONS = 35L

    /// Tri-state library load: null = not tried, true/false = loaded / unavailable. Lazy and
    /// failure-safe exactly like [VortxCore.isAvailable] (same .so, so a success there is a
    /// success here; System.loadLibrary is idempotent per process): an APK built without the
    /// Rust toolchain simply reports unavailable and torrents fall back to the clear error.
    @Volatile
    private var loadState: Boolean? = null

    /// Load `libvortx_ffi.so` once; true when the native surface is callable. Never throws.
    fun isAvailable(): Boolean {
        loadState?.let { return it }
        synchronized(this) {
            loadState?.let { return it }
            val ok = runCatching { System.loadLibrary("vortx_ffi") }
                .onFailure { Log.w(TAG, "libvortx_ffi.so unavailable; in-process streaming server disabled", it) }
                .isSuccess
            loadState = ok
            return ok
        }
    }

    /// The kill switch (see [FLAG_KEY]). Read per torrent resolve, a user-initiated action, so
    /// a Settings flip takes effect on the next play without any restart.
    fun streamingEnabled(context: Context): Boolean = context.applicationContext
        .getSharedPreferences(SourcePreferencesStore.PREFS_FILE, Context.MODE_PRIVATE)
        .getBoolean(FLAG_KEY, true)

    // ---- The JNI surface (call only after isAvailable() returned true) ----

    /// Start the streaming server in-process over `{"serverHome":"...","port":0,...}` (the same
    /// camelCase config document as the C `vortx_server_start`). BLOCKS until bound and serving.
    /// Returns the server handle, 0 on bad input / any start failure. Free exactly once with
    /// [nativeStop].
    external fun nativeStart(configJson: String): Long

    /// The ACTUAL bound port (the ephemeral port `port: 0` bound). 0 on the 0 handle.
    external fun nativePort(handle: Long): Int

    /// The advertised base URL, `http://127.0.0.1:PORT`. Null on the 0 handle.
    external fun nativeBaseUrl(handle: Long): String?

    /// Graceful stop + free; the handle is CONSUMED (zero your copy). Safe with 0. Blocks up to
    /// ~4 s if streams are open, milliseconds when idle.
    external fun nativeStop(handle: Long)

    // ---- Process-scoped lifecycle manager ----

    /// The live server handle (0 = not running) + its base URL. Written only under the object
    /// monitor; volatile so [baseUrlOrNull] is an uncontended read on the play path.
    @Volatile
    private var handle: Long = 0L

    @Volatile
    private var baseUrl: String? = null

    /// One-shot warn guard so a persistently failing start logs once per process, not per play.
    @Volatile
    private var warnedStartFailed = false

    /// Start-on-demand, idempotent: returns the running server's base URL, starting it first if
    /// needed, or null when the native library is absent or the server cannot start (the caller
    /// then falls back to the pre-server behavior, a clear error). Blocks briefly on the FIRST
    /// call (bind); call from a worker thread. Process-scoped: once up, the server stays up for
    /// the app process lifetime (matching the Apple in-process server and the engine handles'
    /// "the OS reclaims it with the process" discipline); [stop] exists for an explicit teardown.
    @Synchronized
    fun startIfNeeded(context: Context): String? {
        baseUrl?.let { return it }
        if (!isAvailable()) return null
        val home = File(context.applicationContext.cacheDir, SERVER_HOME_DIR)
        if (!home.isDirectory && !home.mkdirs()) {
            warnStartOnce("server home not creatable: ${home.absolutePath}")
            return null
        }
        val config = JSONObject()
            .put("serverHome", home.absolutePath)
            .put("port", 0) // ephemeral: never collide with anything else on the device
            .put("cacheSize", CACHE_SIZE_BYTES)
            .put("btMaxConnections", BT_MAX_CONNECTIONS)
        val started = nativeStart(config.toString())
        if (started == 0L) {
            warnStartOnce("in-process streaming server failed to start (nativeStart returned 0)")
            return null
        }
        val url = nativeBaseUrl(started)
        if (url.isNullOrBlank()) {
            // Defensive: a live handle always has a base URL; treat the impossible as a failed
            // start and free the handle rather than leaking a server we cannot address.
            nativeStop(started)
            warnStartOnce("in-process streaming server bound but returned no base URL")
            return null
        }
        handle = started
        baseUrl = url
        Log.i(TAG, "in-process streaming server up at $url (home=${home.absolutePath})")
        return url
    }

    /// The running server's base URL without starting it (null when not running). The cheap
    /// read for code that only wants to KNOW, never to boot the server.
    fun baseUrlOrNull(): String? = baseUrl

    /// Graceful stop + free, idempotent. Blocks briefly; call from a worker thread. The next
    /// [startIfNeeded] starts a fresh server (new ephemeral port).
    @Synchronized
    fun stop() {
        val current = handle
        handle = 0L
        baseUrl = null
        if (current != 0L) nativeStop(current)
    }

    private fun warnStartOnce(message: String) {
        if (warnedStartFailed) return
        warnedStartFailed = true
        Log.w(TAG, message)
    }
}
