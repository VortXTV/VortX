// StremioX desktop app logic. The shared stremio-core engine embeds directly in the Tauri backend
// (Rust↔Rust, no FFI). This file owns the Runtime (like the Apple core's lib.rs) and exposes it to
// the frontend through Tauri commands + an event channel, instead of a C ABI:
//   * `.setup()` hydrates persisted buckets from the OS app-data dir, builds the Runtime, and spawns
//     the event loop, which emits each RuntimeEvent to the frontend as a `core-event`.
//   * `engine_dispatch(action_json)` dispatches a `{ field?, action }` to the Runtime.
//   * `engine_get_state(field_json)` returns a model field as JSON.
// The libmpv player lands on top of this next.

mod engine;
mod model;

use std::sync::RwLock;

use futures::StreamExt;
use once_cell::sync::Lazy;
use serde::Deserialize;
use tauri::{Emitter, Manager};

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

use crate::engine::DesktopEnv;
use crate::model::{DesktopModel, DesktopModelField};

static RUNTIME: Lazy<RwLock<Option<Runtime<DesktopEnv, DesktopModel>>>> = Lazy::new(Default::default);

/// Build the engine: hydrate persisted buckets from `storage_dir`, construct the Runtime, and spawn
/// the event loop that forwards every RuntimeEvent (as JSON) to `on_event`. Mirrors the Apple core's
/// `stremiox_core_init` (and stremio-core-web's `initialize_runtime`). Idempotent.
fn init_engine<F: Fn(String) + Send + Sync + 'static>(storage_dir: String, on_event: F) {
    if RUNTIME.read().ok().map(|g| g.is_some()).unwrap_or(true) {
        return; // already initialized (or lock poisoned — don't re-init)
    }
    engine::set_storage_dir(storage_dir);

    let (profile, recent, other, streams, server_urls, notifications, search_history, dismissed) =
        engine::block_on(async {
            futures::join!(
                DesktopEnv::get_storage::<Profile>(PROFILE_STORAGE_KEY),
                DesktopEnv::get_storage::<LibraryBucket>(LIBRARY_RECENT_STORAGE_KEY),
                DesktopEnv::get_storage::<LibraryBucket>(LIBRARY_STORAGE_KEY),
                DesktopEnv::get_storage::<StreamsBucket>(STREAMS_STORAGE_KEY),
                DesktopEnv::get_storage::<ServerUrlsBucket>(STREAMING_SERVER_URLS_STORAGE_KEY),
                DesktopEnv::get_storage::<NotificationsBucket>(NOTIFICATIONS_STORAGE_KEY),
                DesktopEnv::get_storage::<SearchHistoryBucket>(SEARCH_HISTORY_STORAGE_KEY),
                DesktopEnv::get_storage::<DismissedEventsBucket>(DISMISSED_EVENTS_STORAGE_KEY),
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
        .unwrap_or_else(|| ServerUrlsBucket::new::<DesktopEnv>(profile.uid()));
    let notifications = notifications
        .ok()
        .flatten()
        .unwrap_or_else(|| NotificationsBucket::new::<DesktopEnv>(profile.uid(), vec![]));
    let search_history = search_history
        .ok()
        .flatten()
        .unwrap_or_else(|| SearchHistoryBucket::new(profile.uid()));
    let dismissed = dismissed
        .ok()
        .flatten()
        .unwrap_or_else(|| DismissedEventsBucket::new(profile.uid()));

    let (model, effects) = DesktopModel::new(
        profile,
        library,
        streams,
        streaming_server_urls,
        notifications,
        search_history,
        dismissed,
    );
    let (runtime, rx) =
        Runtime::<DesktopEnv, _>::new(model, effects.into_iter().collect::<Vec<_>>(), 1000);

    // Event loop: serialize each RuntimeEvent and hand it to the frontend.
    DesktopEnv::exec_concurrent(rx.for_each(move |event| {
        if let Ok(json) = serde_json::to_string(&event) {
            on_event(json);
        }
        futures::future::ready(())
    }));

    *RUNTIME.write().expect("runtime write") = Some(runtime);
}

/// `{ "field": <DesktopModelField|null>, "action": <Action> }`
#[derive(Deserialize)]
struct ActionDto {
    #[serde(default)]
    field: Option<DesktopModelField>,
    action: Action,
}

/// stremio-core's storage schema version (proves the engine links + is callable from the frontend).
#[tauri::command]
fn engine_schema_version() -> u32 {
    SCHEMA_VERSION
}

/// Dispatch an action (JSON) to the Runtime. No-op if not initialized or the JSON is invalid.
#[tauri::command]
fn engine_dispatch(action_json: String) {
    let dto: ActionDto = match serde_json::from_str(&action_json) {
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
}

/// Serialize a model field to JSON (field name e.g. `"board"`). Returns `"null"` until initialized.
#[tauri::command]
fn engine_get_state(field_json: String) -> String {
    let field: DesktopModelField = match serde_json::from_str(&field_json) {
        Ok(field) => field,
        Err(_) => return "null".to_owned(),
    };
    match RUNTIME.read() {
        Ok(guard) => match guard.as_ref() {
            Some(runtime) => match runtime.model() {
                Ok(model) => model.get_state_json(&field),
                Err(_) => "null".to_owned(),
            },
            None => "null".to_owned(),
        },
        Err(_) => "null".to_owned(),
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let handle = app.handle().clone();
            // Persist buckets under the OS app-data dir (e.g. ~/Library/Application Support/...).
            let storage_dir = app
                .path()
                .app_data_dir()
                .map(|dir| dir.join("engine").to_string_lossy().into_owned())
                .unwrap_or_else(|_| "stremiox-engine".to_owned());
            init_engine(storage_dir, move |json| {
                let _ = handle.emit("core-event", json);
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            engine_schema_version,
            engine_dispatch,
            engine_get_state
        ])
        .run(tauri::generate_context!())
        .expect("error while running the StremioX desktop app");
}
