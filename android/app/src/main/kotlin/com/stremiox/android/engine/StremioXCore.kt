package com.stremiox.android.engine

/// The raw JNI surface to the shared stremio-core engine (the same Rust engine the iOS/tvOS apps use).
///
/// This object is the Android analogue of the Apple `CoreBridge`'s C-ABI layer: it loads the native
/// library (`libstremiox_core.so`, built from `core/` as a cdylib via cargo-ndk) and exposes the four
/// engine entry points as `external fun`s. Everything crosses the boundary as JSON (serde on the Rust
/// side), exactly like the Apple bridge, so there is one engine contract shared by every platform.
///
/// The names here are deliberately `stremiox*` and `com.stremiox.android.engine.StremioXCore`: the
/// VortX rebrand keeps all internal identifiers as `stremiox` (the JNI symbol names in
/// `core/src/android_jni.rs` are derived from this exact package + class, so renaming either side
/// breaks the dynamic link). Do not rename without updating both sides together.
///
/// Lifecycle (mirrors the Apple `stremiox_core_init` contract):
///   1. [init] once at app start with the app's files dir (durable storage) and cache dir, plus a
///      [EventListener]. Hydrates persisted buckets, builds the Runtime, starts the event loop.
///   2. [dispatch] JSON actions to drive screens (`{ "field": <name|null>, "action": <Action> }`).
///   3. [getState] to pull a model field's JSON after an event says it changed.
///   4. The engine calls [EventListener.onEvent] (on a native worker thread, already attached to the
///      JVM by the Rust side) with a JSON `RuntimeEvent` for every model change.
object StremioXCore {

    /// A sink for engine `RuntimeEvent`s. Implemented by the repository layer to translate "field X
    /// changed" into a state refresh. Invoked on a native (non-main) thread, so implementations must
    /// not touch the UI directly and must be thread-safe.
    fun interface EventListener {
        /// One serialized `RuntimeEvent`, e.g. `{"name":"NewState","args":["board","ctx"]}`. The
        /// bytes are UTF-8 JSON. Decode, react (typically re-pull the named fields via [getState]),
        /// and return promptly: the engine event loop is blocked until this returns.
        fun onEvent(json: ByteArray)
    }

    @Volatile
    private var initialized = false

    init {
        // Matches the cdylib `name = "stremiox_core"` in core/Cargo.toml, which produces
        // libstremiox_core.so. The .so must be packaged under jniLibs/<abi>/ (see build.gradle.kts
        // externalNativeBuild / cargo-ndk output) so the loader finds it at runtime.
        System.loadLibrary("stremiox_core")
    }

    /// Initialize the engine. Safe to call more than once; the native side is idempotent and returns
    /// `true` if already initialized. [storageDir] must be durable (the app's `filesDir`); [cacheDir]
    /// may be OS-purgeable (`cacheDir`). Returns `true` on success.
    @Synchronized
    fun init(storageDir: String, cacheDir: String, listener: EventListener): Boolean {
        if (initialized) return true
        initialized = nativeInit(storageDir, cacheDir, listener)
        return initialized
    }

    /// Dispatch a JSON action: `{ "field": <field-name|null>, "action": <Action JSON> }`. No-op if the
    /// engine is not initialized or the JSON is malformed (the native side swallows parse errors,
    /// matching the Apple contract). Use [EngineActions] to build well-formed payloads.
    fun dispatch(actionJson: String) {
        nativeDispatch(actionJson)
    }

    /// Serialize a model field to JSON by its field name (e.g. `"board"`, `"meta_details"`). Returns
    /// the literal string `"null"` if the field is unknown or the engine is not ready; never returns
    /// a Kotlin null, so callers can always hand the result to a JSON parser.
    fun getState(fieldJson: String): String = nativeGetState(fieldJson)

    /// stremio-core's storage schema version. A cheap smoke test that the native library linked and
    /// the engine is callable end to end.
    fun schemaVersion(): Int = nativeSchemaVersion()

    // ---- JNI declarations. Implemented in core/src/android_jni.rs; symbol names are derived from
    //      this package + class + method, so keep them in lockstep with the Rust side. ----

    private external fun nativeInit(
        storageDir: String,
        cacheDir: String,
        listener: EventListener,
    ): Boolean

    private external fun nativeDispatch(actionJson: String)

    private external fun nativeGetState(fieldJson: String): String

    private external fun nativeSchemaVersion(): Int
}
