//! Android JNI surface for the StremioX core, the Kotlin ⇄ Rust bridge over **stremio-core**.
//!
//! This is the Android analogue of the Apple C ABI in `lib.rs`. It exposes the *same* engine, the
//! *same* JSON contract (serde), and the *same* lifecycle, but to Kotlin via the `jni` crate instead
//! of to Swift via a C ABI. Compiled only for `target_os = "android"` (the crate ships a `cdylib`
//! crate-type so this links into `libstremiox_core.so`); the Apple staticlib build never sees it.
//!
//! Kotlin entry points (all on `com.stremiox.android.engine.StremioXCore`):
//!   - `nativeInit(storageDir, cacheDir, listener)` -> `boolean`
//!         Hydrate buckets, build the Runtime, start the event loop. `listener` is a Kotlin object
//!         implementing `EventListener { fun onEvent(json: ByteArray) }`; the Rust event loop calls
//!         it (on a worker thread, attached to the JVM) for every `RuntimeEvent`.
//!   - `nativeDispatch(actionJson)` -> `void`     `{ "field": <field|null>, "action": <Action> }`.
//!   - `nativeGetState(fieldJson)`  -> `String`    serialized model field, or `"null"`.
//!   - `nativeSchemaVersion()`      -> `int`       smoke test that the engine links + runs.
//!
//! Threading: stremio-core's effects run on the crate's own tokio worker threads (see `env.rs`), so
//! the event loop fires `onEvent` from a thread the JVM has never seen. We cache the `JavaVM` in
//! `JNI_OnLoad` and `attach_current_thread` on each callback, the standard jni-rs pattern for native
//! threads calling into managed code. The listener is held as a `GlobalRef` so it survives past the
//! `nativeInit` call frame for the lifetime of the process.

use std::sync::RwLock;

use jni::objects::{GlobalRef, JByteArray, JClass, JObject, JString};
use jni::sys::{jboolean, jint, JNI_VERSION_1_6, JNI_FALSE, JNI_TRUE};
use jni::{JNIEnv, JavaVM};
use once_cell::sync::Lazy;

use stremio_core::constants::SCHEMA_VERSION;

use crate::EventSink;

/// The `JavaVM`, cached in `JNI_OnLoad`. Needed so the engine's tokio worker threads (which the JVM
/// never started) can attach themselves before calling the Kotlin listener back.
static JAVA_VM: Lazy<RwLock<Option<JavaVM>>> = Lazy::new(Default::default);

/// A global ref to the Kotlin `EventListener` plus the cached `onEvent([B)V` method id. Held for the
/// process lifetime (the event loop never stops), mirroring the Apple "callback valid forever"
/// contract. `jmethodID` is `Send`/`Sync`-safe to cache; we wrap it so the whole struct can live in a
/// static.
struct Listener {
    object: GlobalRef,
}

static LISTENER: Lazy<RwLock<Option<Listener>>> = Lazy::new(Default::default);

/// Cached so we never relookup the class/method on the hot event path. The method is
/// `EventListener.onEvent(json: ByteArray): Unit`.
const LISTENER_ON_EVENT: &str = "onEvent";
const LISTENER_ON_EVENT_SIG: &str = "([B)V";

/// Standard JNI load hook. Caches the `JavaVM` so native threads can attach later. Returning a JNI
/// version (not a bool) is the JNI ABI contract.
///
/// # Safety
/// Called by the JVM exactly once at `System.loadLibrary`. `vm` is a valid `JavaVM` pointer.
#[no_mangle]
pub extern "system" fn JNI_OnLoad(vm: JavaVM, _reserved: *mut std::ffi::c_void) -> jint {
    if let Ok(mut guard) = JAVA_VM.write() {
        *guard = Some(vm);
    }
    JNI_VERSION_1_6
}

/// `StremioXCore.nativeSchemaVersion(): Int`
#[no_mangle]
pub extern "system" fn Java_com_stremiox_android_engine_StremioXCore_nativeSchemaVersion(
    _env: JNIEnv,
    _class: JClass,
) -> jint {
    SCHEMA_VERSION as jint
}

/// `StremioXCore.nativeInit(storageDir: String, cacheDir: String, listener: EventListener): Boolean`
///
/// Stores the listener as a global ref, builds the host event sink (attach-thread + call `onEvent`),
/// and delegates to the shared `init_runtime`. Idempotent: a second call while already initialized
/// returns `true` without rebuilding (matches the Apple contract).
#[no_mangle]
pub extern "system" fn Java_com_stremiox_android_engine_StremioXCore_nativeInit<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    storage_dir: JString<'local>,
    cache_dir: JString<'local>,
    listener: JObject<'local>,
) -> jboolean {
    let storage_dir: String = match env.get_string(&storage_dir) {
        Ok(value) => value.into(),
        Err(_) => return JNI_FALSE,
    };
    let cache_dir: String = match env.get_string(&cache_dir) {
        Ok(value) => value.into(),
        Err(_) => return JNI_FALSE,
    };

    // Promote the listener to a global ref so it outlives this call frame; the event loop holds it
    // for the process lifetime.
    match env.new_global_ref(&listener) {
        Ok(global) => {
            if let Ok(mut guard) = LISTENER.write() {
                *guard = Some(Listener { object: global });
            }
        }
        Err(_) => return JNI_FALSE,
    }

    let sink: EventSink = Box::new(|json: &[u8]| {
        deliver_event(json);
    });

    if crate::init_runtime(storage_dir, cache_dir, sink) {
        JNI_TRUE
    } else {
        JNI_FALSE
    }
}

/// `StremioXCore.nativeDispatch(actionJson: String)`
#[no_mangle]
pub extern "system" fn Java_com_stremiox_android_engine_StremioXCore_nativeDispatch<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    action_json: JString<'local>,
) {
    let json: String = match env.get_string(&action_json) {
        Ok(value) => value.into(),
        Err(_) => return,
    };
    crate::dispatch_json(&json);
}

/// `StremioXCore.nativeGetState(fieldJson: String): String`
///
/// Returns a Java `String` of the serialized field, or `"null"` on any error. Never returns a JVM
/// null reference (callers can always parse the result).
#[no_mangle]
pub extern "system" fn Java_com_stremiox_android_engine_StremioXCore_nativeGetState<'local>(
    mut env: JNIEnv<'local>,
    _class: JClass<'local>,
    field_json: JString<'local>,
) -> JString<'local> {
    let field: String = match env.get_string(&field_json) {
        Ok(value) => value.into(),
        Err(_) => "null".to_owned(),
    };
    let state = crate::get_state_json(&field);
    env.new_string(state)
        .unwrap_or_else(|_| env.new_string("null").expect("static 'null' string"))
}

/// Attach the current (tokio worker) thread to the JVM and invoke `listener.onEvent(json)`. Called
/// from the engine event loop for every `RuntimeEvent`. All errors are swallowed: a dropped event is
/// recoverable (the Kotlin side re-pulls fields on the next event), a panic across the JNI boundary
/// is not.
fn deliver_event(json: &[u8]) {
    let vm_guard = match JAVA_VM.read() {
        Ok(guard) => guard,
        Err(_) => return,
    };
    let vm = match vm_guard.as_ref() {
        Some(vm) => vm,
        None => return,
    };

    // `attach_current_thread` returns a guard that detaches on drop. The event loop threads are
    // long-lived, so repeated attach/detach is acceptable overhead for the simplest-correct path; if
    // profiling ever flags it, switch to `attach_current_thread_permanently`.
    let mut env = match vm.attach_current_thread() {
        Ok(env) => env,
        Err(_) => return,
    };

    let listener_guard = match LISTENER.read() {
        Ok(guard) => guard,
        Err(_) => return,
    };
    let listener = match listener_guard.as_ref() {
        Some(listener) => listener,
        None => return,
    };

    let byte_array: JByteArray = match env.byte_array_from_slice(json) {
        Ok(array) => array,
        Err(_) => return,
    };

    // Call onEvent([B)V. Errors (including a pending Java exception) are cleared and ignored so the
    // event loop keeps running.
    let result = env.call_method(
        listener.object.as_obj(),
        LISTENER_ON_EVENT,
        LISTENER_ON_EVENT_SIG,
        &[(&byte_array).into()],
    );
    if result.is_err() {
        let _ = env.exception_clear();
    }
}
