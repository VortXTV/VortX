//! StremioX native core, Rust ⇄ Swift FFI bridge over **stremio-core** (the real Stremio engine).
//!
//! Re-bases the tvOS app onto the same engine the official app uses, instead of the hand-rolled
//! addon/library client. Mirrors `stremio-core-kotlin`'s native pattern but exposes a **C ABI** for
//! Swift and serializes state as **JSON** (serde) instead of protobuf, Swift decodes with Codable.
//!
//! Lifecycle:
//!   `stremiox_core_init(storage_dir, cache_dir, ctx, on_event)`, hydrate buckets from storage,
//!       build the Runtime, spawn the event loop. After this, `continue_watching_preview` is already
//!       populated from the persisted library (no action needed).
//!   `stremiox_core_dispatch(action_json)`, `{ "field": <field|null>, "action": <Action> }`.
//!   `stremiox_core_get_state(field_json)`, returns malloc'd JSON; free with `stremiox_core_string_free`.
//!   `on_event(ctx, ptr, len)`, fired (on a worker thread) with a JSON `RuntimeEvent`
//!       (e.g. `{"name":"NewState","args":["board","ctx"]}`); copy synchronously, then re-pull fields.

mod env;
mod model;

use std::ffi::{c_char, CStr, CString};
use std::os::raw::c_void;
use std::panic::AssertUnwindSafe;
use std::sync::RwLock;

use futures::StreamExt;
use once_cell::sync::Lazy;
use serde::Deserialize;

use stremio_core::constants::{
    DISMISSED_EVENTS_STORAGE_KEY, LIBRARY_RECENT_STORAGE_KEY, LIBRARY_STORAGE_KEY,
    NOTIFICATIONS_STORAGE_KEY, PROFILE_STORAGE_KEY, SCHEMA_VERSION, SEARCH_HISTORY_STORAGE_KEY,
    STREAMING_SERVER_URLS_STORAGE_KEY, STREAMS_STORAGE_KEY,
};
use stremio_core::runtime::msg::Action;
use stremio_core::runtime::{Env, Runtime, RuntimeAction};
use stremio_core::types::events::DismissedEventsBucket;
use stremio_core::types::library::LibraryBucket;
use stremio_core::types::notifications::NotificationsBucket;
use stremio_core::types::profile::Profile;
use stremio_core::types::search_history::SearchHistoryBucket;
use stremio_core::types::server_urls::ServerUrlsBucket;
use stremio_core::types::streams::StreamsBucket;

use crate::env::TvosEnv;
use crate::model::{TvosModel, TvosModelField};

static RUNTIME: Lazy<RwLock<Option<Runtime<TvosEnv, TvosModel>>>> = Lazy::new(Default::default);

/// Swift-supplied callback for `RuntimeEvent`s. `ctx` is an opaque pointer Swift hands back to itself.
type EventCallback = extern "C" fn(ctx: *mut c_void, data: *const u8, len: usize);

struct Callback {
    cb: EventCallback,
    ctx: *mut c_void,
}
// SAFETY: the host guarantees `ctx` (an opaque Swift pointer) stays valid for the app's lifetime and
// that `cb` is thread-safe; we only ever read these fields and call through them.
unsafe impl Send for Callback {}
unsafe impl Sync for Callback {}

static EVENT_CB: Lazy<RwLock<Option<Callback>>> = Lazy::new(Default::default);

/// Smoke milestone (kept): stremio-core's storage schema version.
#[no_mangle]
pub extern "C" fn stremiox_core_schema_version() -> u32 {
    SCHEMA_VERSION
}

/// Initialize the engine. Returns `true` on success (or if already initialized).
///
/// # Safety
/// `storage_dir` and `cache_dir` must be valid NUL-terminated C strings; `on_event`/`cb_ctx` must
/// remain valid for the lifetime of the app (the event loop never stops).
#[no_mangle]
pub extern "C" fn stremiox_core_init(
    storage_dir: *const c_char,
    cache_dir: *const c_char,
    cb_ctx: *mut c_void,
    on_event: EventCallback,
) -> bool {
    let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| {
        if RUNTIME.read().ok().map(|guard| guard.is_some()).unwrap_or(true) {
            return true; // already initialized (or lock poisoned, don't re-init)
        }
        let storage_dir = unsafe { CStr::from_ptr(storage_dir) }.to_string_lossy().into_owned();
        let cache_dir = unsafe { CStr::from_ptr(cache_dir) }.to_string_lossy().into_owned();
        env::set_storage_dir(storage_dir);
        // fetch.rs-style HTTP cache lives under TMPDIR; point it at the host's caches dir.
        std::env::set_var("TMPDIR", &cache_dir);
        *EVENT_CB.write().expect("event cb write") = Some(Callback { cb: on_event, ctx: cb_ctx });

        // Run storage-schema migrations (v1..=SCHEMA_VERSION), best-effort.
        let _ = env::block_on(TvosEnv::migrate_storage_schema());

        // Hydrate persisted buckets (mirrors stremio-core-web::initialize_runtime).
        let (profile, recent, other, streams, server_urls, notifications, search_history, dismissed) =
            env::block_on(async {
                futures::join!(
                    TvosEnv::get_storage::<Profile>(PROFILE_STORAGE_KEY),
                    TvosEnv::get_storage::<LibraryBucket>(LIBRARY_RECENT_STORAGE_KEY),
                    TvosEnv::get_storage::<LibraryBucket>(LIBRARY_STORAGE_KEY),
                    TvosEnv::get_storage::<StreamsBucket>(STREAMS_STORAGE_KEY),
                    TvosEnv::get_storage::<ServerUrlsBucket>(STREAMING_SERVER_URLS_STORAGE_KEY),
                    TvosEnv::get_storage::<NotificationsBucket>(NOTIFICATIONS_STORAGE_KEY),
                    TvosEnv::get_storage::<SearchHistoryBucket>(SEARCH_HISTORY_STORAGE_KEY),
                    TvosEnv::get_storage::<DismissedEventsBucket>(DISMISSED_EVENTS_STORAGE_KEY),
                )
            });

        let profile = profile.ok().flatten().unwrap_or_default();
        let mut library = LibraryBucket::new(profile.uid(), vec![]);
        if let Ok(Some(recent)) = recent {
            library.merge_bucket(recent);
        }
        if let Ok(Some(other)) = other {
            library.merge_bucket(other);
        }
        let streams = streams.ok().flatten().unwrap_or_else(|| StreamsBucket::new(profile.uid()));
        let streaming_server_urls = server_urls
            .ok()
            .flatten()
            .unwrap_or_else(|| ServerUrlsBucket::new::<TvosEnv>(profile.uid()));
        let notifications = notifications
            .ok()
            .flatten()
            .unwrap_or_else(|| NotificationsBucket::new::<TvosEnv>(profile.uid(), vec![]));
        let search_history = search_history
            .ok()
            .flatten()
            .unwrap_or_else(|| SearchHistoryBucket::new(profile.uid()));
        let dismissed = dismissed
            .ok()
            .flatten()
            .unwrap_or_else(|| DismissedEventsBucket::new(profile.uid()));

        let (model, effects) = TvosModel::new(
            profile,
            library,
            streams,
            streaming_server_urls,
            notifications,
            search_history,
            dismissed,
        );
        let (runtime, rx) =
            Runtime::<TvosEnv, _>::new(model, effects.into_iter().collect::<Vec<_>>(), 1000);

        // Event loop: serialize each RuntimeEvent to JSON and hand it to the Swift callback.
        TvosEnv::exec_concurrent(rx.for_each(|event| {
            if let Ok(json) = serde_json::to_vec(&event) {
                if let Ok(guard) = EVENT_CB.read() {
                    if let Some(callback) = guard.as_ref() {
                        (callback.cb)(callback.ctx, json.as_ptr(), json.len());
                    }
                }
            }
            futures::future::ready(())
        }));

        *RUNTIME.write().expect("runtime write") = Some(runtime);
        true
    }));
    outcome.unwrap_or(false)
}

/// `{ "field": <TvosModelField|null>, "action": <Action> }`
#[derive(Deserialize)]
struct ActionDto {
    #[serde(default)]
    field: Option<TvosModelField>,
    action: Action,
}

/// Dispatch an action (JSON). No-op if not initialized or the JSON is invalid.
///
/// # Safety
/// `action_json` must be a valid NUL-terminated C string.
#[no_mangle]
pub extern "C" fn stremiox_core_dispatch(action_json: *const c_char) {
    let _ = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let json = match unsafe { CStr::from_ptr(action_json) }.to_str() {
            Ok(json) => json,
            Err(_) => return,
        };
        let dto: ActionDto = match serde_json::from_str(json) {
            Ok(dto) => dto,
            Err(_) => return,
        };
        if let Ok(guard) = RUNTIME.read() {
            if let Some(runtime) = guard.as_ref() {
                runtime.dispatch(RuntimeAction {
                    field: dto.field,
                    action: dto.action,
                });
            }
        }
    }));
}

/// Serialize a model field to JSON. Returns a malloc'd C string (free with `stremiox_core_string_free`).
///
/// # Safety
/// `field_json` must be a valid NUL-terminated C string (a JSON field name, e.g. `"board"`).
#[no_mangle]
pub extern "C" fn stremiox_core_get_state(field_json: *const c_char) -> *mut c_char {
    let outcome = std::panic::catch_unwind(AssertUnwindSafe(|| {
        let json = unsafe { CStr::from_ptr(field_json) }.to_str().unwrap_or("null");
        let field: TvosModelField = match serde_json::from_str(json) {
            Ok(field) => field,
            Err(_) => return to_c_string("null"),
        };
        let state = match RUNTIME.read() {
            Ok(guard) => match guard.as_ref() {
                Some(runtime) => match runtime.model() {
                    Ok(model) => model.get_state_json(&field),
                    Err(_) => "null".to_owned(),
                },
                None => "null".to_owned(),
            },
            Err(_) => "null".to_owned(),
        };
        to_c_string(&state)
    }));
    outcome.unwrap_or_else(|_| to_c_string("null"))
}

fn to_c_string(value: &str) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("null").expect("static cstr"))
        .into_raw()
}

/// Free a string returned by `stremiox_core_get_state`.
///
/// # Safety
/// `ptr` must be a pointer previously returned by this library, and must not be used afterwards.
#[no_mangle]
pub extern "C" fn stremiox_core_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` was produced by `CString::into_raw` in this library; reclaim and drop it.
        unsafe { drop(CString::from_raw(ptr)) };
    }
}
