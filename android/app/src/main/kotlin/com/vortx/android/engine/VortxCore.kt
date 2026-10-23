package com.vortx.android.engine

import android.util.Log

/// The raw JNI surface to the OWN vortx-core engine (`libvortx_ffi.so`, built from the engine
/// branch's `vortx-core/crates/ffi` cdylib with `--no-default-features --features jni`; see
/// `android/app/src/main/jniLibs/README.md` for the build step). The Android twin of the Apple
/// VortxBridge: everything crosses the boundary as JSON on the engine's frozen wire, and the
/// symbols wrap the SAME kernel seam calls as the 7-symbol C ABI.
///
/// This is the app's engine binding (`libvortx_ffi.so`).
///
/// The package + class are `com.vortx.android.engine.VortxCore` and the Rust exports in
/// `vortx-core/crates/ffi/src/jni.rs` are derived from that exact package + class
/// (`Java_com_vortx_android_engine_VortxCore_*`), so renaming either side breaks the dynamic link.
/// Do not rename without updating both sides together.
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

    /// Cold-load a previously captured full state. Zero rejects invalid snapshots; never seed a
    /// fresh account after failure. Requires the audited hydration-capable native artifact.
    external fun nativeInitFromStateJson(stateJson: String): Long

    /// Apply one JSON action at host time (the native side injects the Unix-seconds clock, the
    /// `SystemEnv` semantics). Returns the `DispatchResult` JSON; null only on a native panic.
    external fun nativeDispatchJson(handle: Long, actionJson: String): String?

    /// Resolve one JSON request (read-only). Returns the `ResolveResponse` JSON; a 0 handle or bad
    /// request comes back as well-formed error JSON, null only on a native panic.
    external fun nativeResolveJson(handle: Long, requestJson: String): String?

    /// The full state document JSON (`{}` for a 0 handle); null only on a native panic.
    external fun nativeGetStateJson(handle: Long): String?

    /// Changed records since the last pull; drains the dirty set. Serialize with every handle call.
    external fun nativeGetStateDeltaJson(handle: Long): String?

    /// Free a runtime returned by [nativeInitRuntime]. Safe with 0; free exactly once.
    external fun nativeEngineFree(handle: Long)

    // Additive resource-host ABI. Call only with an artifact that passes the resource-host symbol
    // gate. Host/cancel lifetimes are managed by VortxJniResourceTransport, never by UI callbacks.
    external fun nativeResourceHostNew(): Long
    external fun nativeResourceHostAbiVersion(): Int
    external fun nativeResourceHostLoadJson(host: Long, requestJson: String, cancel: Long): String?
    external fun nativeResourceHostFree(host: Long)
    external fun nativeCancelNew(): Long
    external fun nativeCancelCancel(cancel: Long)
    external fun nativeCancelFree(cancel: Long)

    // Additive byte-oriented owner-history ABI. These handles are opaque registry IDs, NOT
    // nativeInitRuntime Engine* values. No automatic activation or fallback to the old ABI.
    // The verifier is borrowed synchronously for ONE call; exceptions reject it.
    external fun nativeOwnerHistoryCanonicalize(evidence: ByteArray): ByteArray?
    external fun nativeOwnerHistoryOpen(snapshot: ByteArray, verifier: NativeOwnerHistoryVerifier): Long
    external fun nativeOwnerHistoryFork(handle: Long, fence: ByteArray, verifier: NativeOwnerHistoryVerifier): Long
    external fun nativeOwnerHistoryRequest(handle: Long, json: ByteArray, now: Long, verifier: NativeOwnerHistoryVerifier): ByteArray?
    external fun nativeOwnerHistoryClose(handle: Long): Boolean
}
