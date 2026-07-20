package com.vortx.android.engine

import android.util.Log

/// The raw JNI surface to the OWN vortx-core engine (`libvortx_ffi.so`, built from the engine
/// branch's `vortx-core/crates/ffi` cdylib with `--no-default-features --features jni`; see
/// `android/app/src/main/jniLibs/README.md` for the build step). The Android twin of the Apple
/// VortxBridge: everything crosses the boundary as JSON on the engine's frozen wire, and the
/// symbols wrap the SAME kernel seam calls as the 7-symbol C ABI.
///
/// This binding is the Phase 7 slice-1 SHADOW lane only: [VortxRankingShadow] drives
/// [nativeResolveJson] behind a default-OFF flag to measure rank agreement. The shipping engine
/// remains [StremioCoreNative] (`libstremiox_core.so`); nothing user-visible reads this object yet.
///
/// The package + class are `com.vortx.android.engine.VortxCore` and the Rust exports in
/// `vortx-core/crates/ffi/src/jni.rs` are derived from that exact package + class
/// (`Java_com_vortx_android_engine_VortxCore_*`), so renaming either side breaks the dynamic link.
/// Do not rename without updating both sides together (the same rule as [StremioCoreNative]).
///
/// Threading: the handle is one-call-at-a-time (the engine crate's documented discipline).
/// [VortxRankingShadow] serializes its calls; any future caller must do the same per handle.
object VortxCore {

    private const val TAG = "VortxCore"

    /// Tri-state library load: null = not tried, true/false = loaded / unavailable. Loading is
    /// LAZY and failure-safe (unlike an `init {}` loadLibrary) so an APK missing the .so (a build
    /// without the Rust toolchain) can never crash the app just by touching this class: the shadow
    /// lane simply reports unavailable and stays silent.
    @Volatile
    private var loadState: Boolean? = null

    /// Load `libvortx_ffi.so` once; true when the native surface is callable. Never throws.
    fun isAvailable(): Boolean {
        loadState?.let { return it }
        synchronized(this) {
            loadState?.let { return it }
            val ok = runCatching { System.loadLibrary("vortx_ffi") }
                .onFailure { Log.w(TAG, "libvortx_ffi.so unavailable; vortx-core shadow lane disabled", it) }
                .isSuccess
            loadState = ok
            return ok
        }
    }

    // ---- The JNI surface (call only after isAvailable() returned true) ----

    /// Build a runtime over the owner profile: `{"ownerId":"...","ownerName":"..."}`. Returns the
    /// engine handle, 0 on bad input. Free exactly once with [nativeEngineFree].
    external fun nativeInitRuntime(configJson: String): Long

    /// Apply one JSON action at host time (the native side injects the Unix-seconds clock, the
    /// `SystemEnv` semantics). Returns the `DispatchResult` JSON; null only on a native panic.
    external fun nativeDispatchJson(handle: Long, actionJson: String): String?

    /// Resolve one JSON request (read-only). Returns the `ResolveResponse` JSON; a 0 handle or bad
    /// request comes back as well-formed error JSON, null only on a native panic.
    external fun nativeResolveJson(handle: Long, requestJson: String): String?

    /// The full state document JSON (`{}` for a 0 handle); null only on a native panic.
    external fun nativeGetStateJson(handle: Long): String?

    /// Free a runtime returned by [nativeInitRuntime]. Safe with 0; free exactly once.
    external fun nativeEngineFree(handle: Long)
}
