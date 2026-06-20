// StremioX desktop app logic. The shared stremio-core engine embeds directly in the Tauri backend
// (Rust↔Rust, no FFI). This file owns the Runtime (like the Apple core's lib.rs) and exposes it to
// the frontend through Tauri commands + an event channel, instead of a C ABI:
//   * `.setup()` hydrates persisted buckets from the OS app-data dir, builds the Runtime, and spawns
//     the event loop, which emits each RuntimeEvent to the frontend as a `core-event`.
//   * `engine_dispatch(action_json)` dispatches a `{ field?, action }` to the Runtime.
//   * `engine_get_state(field_json)` returns a model field as JSON.
// On top of this, the mpv (libmpv) player lands as a spawned child process driven over JSON IPC
// (see player.rs), exposed through the `mpv_play` / `mpv_command` / `mpv_stop` / `mpv_status`
// commands; the frontend's resolved (url)=>play sink calls these instead of injecting a webview
// <video>.

mod engine;
mod model;
mod player;
mod server;

use std::sync::RwLock;

use futures::StreamExt;
use once_cell::sync::Lazy;
use serde::Deserialize;
use serde_json::Value;
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

/// The embedded streaming server's current state (JSON-tagged `state` + `reason`). The frontend
/// renders an empty state from this when the server failed to start, and stops filtering out torrent
/// streams once it is running + listening.
#[tauri::command]
fn server_status() -> server::ServerState {
    server::status()
}

/// The base URL of the embedded streaming server (`http://127.0.0.1:11470`). The frontend builds the
/// torrent prime (`POST <base>/<infohash>/create`) and play (`<base>/<infohash>/<fileIdx>`) URLs from
/// this — the StremioServer-equivalent on desktop.
#[tauri::command]
fn server_base_url() -> String {
    server::base_url()
}

/// Whether the embedded server is actually accepting connections on the loopback port yet (it spawns
/// asynchronously and takes a moment to boot). The frontend polls this before relying on the server.
#[tauri::command]
fn server_is_listening() -> bool {
    server::is_listening()
}

// ---- mpv player commands -----------------------------------------------------------------------

/// Play `url` in the embedded mpv player. The URL is whatever the frontend's unchanged
/// prepareTorrent -> resolveUrl pipeline produced: a direct/debrid `https://…` URL, or, for a
/// torrent, only once the embedded server is listening, a `http://127.0.0.1:11470/<hash>/<idx>`
/// loopback URL. The TORRENT GATE is enforced twice: primarily by resolveUrl (which returns null
/// until `isListening()`), and again here by passing the live server-listening state into
/// `player::play`, which refuses a loopback URL while the server is down.
///
/// mpv is embedded into the app's main window surface when a native handle is available, so playback
/// stays inside the app; otherwise mpv opens its own window. `resource_dir` locates the staged mpv
/// binary the same way the embedded node server is located.
#[tauri::command]
fn mpv_play(app: tauri::AppHandle, url: String) -> Result<(), String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("resource dir unavailable: {e}"))?;
    // The embedded server's live liveness, for the defensive torrent-gate backstop in player::play.
    let server_listening = server::is_listening();
    // Try to embed mpv into the main window's native surface. A failure to resolve a handle is not
    // fatal, mpv falls back to its own borderless window.
    let wid = main_window_handle(&app);
    player::play(&resource_dir, &url, wid, server_listening)
}

/// Forward a raw mpv JSON IPC command to the running player and return its reply, e.g.
/// `{"command":["set_property","pause",true]}` (pause), `{"command":["seek",30,"relative"]}` (skip
/// 30s), `{"command":["set_property","volume",80]}`. The frontend's transport controls (pause/seek/
/// volume) go through here; `mpv_stop` handles teardown. Errors if no player is running.
#[tauri::command]
fn mpv_command(command: Value) -> Result<Value, String> {
    player::command(&command)
}

/// Stop playback and tear down the mpv child (force-killed + reaped so it is never orphaned).
#[tauri::command]
fn mpv_stop() {
    player::stop();
}

/// The player's current state (`playing` / `idle` / `failed` + reason), for the player UI's empty
/// and error states. Shape mirrors `server_status`.
#[tauri::command]
fn mpv_status() -> player::PlayerState {
    player::status()
}

/// Resolve the main window's native handle for mpv embedding (`--wid`): the X11 `Window` / Win32
/// `HWND` / macOS `NSView*` as an `isize`. Returns None when the handle can't be obtained, in which
/// case mpv opens its own window. Implemented via raw-window-handle so it stays one code path across
/// the three windowing systems Tauri targets.
fn main_window_handle(app: &tauri::AppHandle) -> Option<isize> {
    let window = app.get_webview_window("main")?;
    raw_handle_isize(&window)
}

#[cfg(target_os = "linux")]
fn raw_handle_isize(window: &tauri::WebviewWindow) -> Option<isize> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        // X11: mpv's --wid takes the X Window id.
        RawWindowHandle::Xlib(h) => Some(h.window as isize),
        // Wayland has no stable --wid embedding for mpv; fall back to mpv's own window.
        _ => None,
    }
}

#[cfg(target_os = "windows")]
fn raw_handle_isize(window: &tauri::WebviewWindow) -> Option<isize> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        RawWindowHandle::Win32(h) => Some(isize::from(h.hwnd)),
        _ => None,
    }
}

#[cfg(target_os = "macos")]
fn raw_handle_isize(window: &tauri::WebviewWindow) -> Option<isize> {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().ok()?.as_raw() {
        // mpv's --wid on macOS takes an NSView pointer.
        RawWindowHandle::AppKit(h) => Some(h.ns_view.as_ptr() as isize),
        _ => None,
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

            // Start the embedded streaming server (bundled node + server.js) on loopback so TORRENT
            // streams play. Resources are staged next to the binary by fetch-server-deps.sh and
            // bundled via tauri.conf.json; the server uses a writable cache dir as its HOME.
            if let Ok(resource_dir) = app.path().resource_dir() {
                let cache_dir = app
                    .path()
                    .app_cache_dir()
                    .unwrap_or_else(|_| std::env::temp_dir())
                    .join("stremio-server");
                server::start(&resource_dir, &cache_dir);
            } else {
                eprintln!("StremioX: resource dir unavailable; embedded server disabled");
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            engine_schema_version,
            engine_dispatch,
            engine_get_state,
            server_status,
            server_base_url,
            server_is_listening,
            mpv_play,
            mpv_command,
            mpv_stop,
            mpv_status
        ])
        .build(tauri::generate_context!())
        .expect("error while running the StremioX desktop app")
        .run(|_app_handle, event| {
            // Never orphan a child process: force-kill the mpv player and the node server when the
            // app is exiting.
            if let tauri::RunEvent::Exit = event {
                player::stop();
                server::stop();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// End-to-end proof that the embedded engine fetches real catalogs on desktop: init, dispatch the
    /// same board-load the Apple app uses (Load CatalogsWithExtra + LoadRange), and poll until the
    /// board state is populated from the default add-ons (Cinemeta). Hits the network, so it is
    /// `#[ignore]`d in normal/CI runs. Run it with:
    ///   cargo test --manifest-path desktop/src-tauri/Cargo.toml engine_fetches_real_board -- --ignored --nocapture
    #[test]
    #[ignore]
    fn engine_fetches_real_board() {
        let dir = std::env::temp_dir()
            .join("stremiox-engine-smoke")
            .to_string_lossy()
            .into_owned();
        let _ = std::fs::remove_dir_all(&dir);
        init_engine(dir, |_json| {});

        // Load every catalog of every installed add-on, then fetch the first 30 rows.
        engine_dispatch(
            r#"{"field":"board","action":{"action":"Load","args":{"model":"CatalogsWithExtra","args":{"type":null,"extra":[]}}}}"#.to_owned(),
        );
        engine_dispatch(
            r#"{"field":"board","action":{"action":"CatalogsWithExtra","args":{"action":"LoadRange","args":{"start":0,"end":30}}}}"#.to_owned(),
        );

        let mut board = String::from("null");
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            board = engine_get_state(r#""board""#.to_owned());
            if board.contains("\"poster\"") {
                break;
            }
        }
        println!("board state ({} bytes): {}", board.len(), &board[..board.len().min(800)]);
        assert!(
            board.contains("\"poster\""),
            "board should populate with real catalog items (posters) from the default add-ons"
        );
    }

    /// Contract test for the desktop **detail page** (src/detail.ts + streamRanking.ts): load
    /// `meta_details` for a known movie the same way the frontend does, and assert the JSON carries
    /// the exact fields the detail UI reads — the per-add-on `streams[].request.base` grouping key,
    /// the `metaItems` envelope, and the hero `logo` / `links` (genres + rating). Hits the network,
    /// so it is `#[ignore]`d like the board test. Run it with:
    ///   cargo test --manifest-path desktop/src-tauri/Cargo.toml meta_details_shape_for_detail_page -- --ignored --nocapture
    #[test]
    #[ignore]
    fn meta_details_shape_for_detail_page() {
        let dir = std::env::temp_dir()
            .join("stremiox-engine-detail-smoke")
            .to_string_lossy()
            .into_owned();
        let _ = std::fs::remove_dir_all(&dir);
        init_engine(dir, |_json| {});

        // The Matrix (tt0133093): a stable, default-add-on (Cinemeta) movie. Same Load envelope the
        // frontend's openDetail() dispatches.
        engine_dispatch(
            r#"{"field":"meta_details","action":{"action":"Load","args":{"model":"MetaDetails","args":{"metaPath":{"resource":"meta","type":"movie","id":"tt0133093","extra":[]},"guessStream":true,"streamPath":null}}}}"#.to_owned(),
        );

        let mut md = String::from("null");
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            md = engine_get_state(r#""meta_details""#.to_owned());
            // Wait until the meta has resolved AND at least one stream group request exists.
            if md.contains("\"logo\"") && md.contains("\"streams\"") {
                break;
            }
        }
        println!("meta_details ({} bytes): {}", md.len(), &md[..md.len().min(1200)]);

        // The detail page parses these exact keys; if the engine ever renames them the UI breaks.
        assert!(md.contains("\"metaItems\""), "meta_details must expose metaItems");
        assert!(md.contains("\"streams\""), "meta_details must expose streams");
        assert!(md.contains("\"links\""), "meta carries links (genres + imdb rating)");
        assert!(
            md.contains("\"base\"") && md.contains("\"path\""),
            "every resource request exposes base (the per-add-on grouping key) + path"
        );
    }

    /// Contract test for the desktop **series detail page** (the series branch in src/detail.ts):
    /// load a known series and assert the meta carries the `videos` array with the season/episode
    /// fields the episode list reads, then load ONE episode's streams the way the frontend does
    /// (the same MetaDetails Load envelope, but with a `streamPath` scoped to the episode's video id)
    /// and assert the per-add-on `streams[].request.base` grouping shape comes back. Hits the
    /// network, so it is `#[ignore]`d like the others. Run it with:
    ///   cargo test --manifest-path desktop/src-tauri/Cargo.toml episode_streams_shape_for_series_page -- --ignored --nocapture
    #[test]
    #[ignore]
    fn episode_streams_shape_for_series_page() {
        let dir = std::env::temp_dir()
            .join("stremiox-engine-series-smoke")
            .to_string_lossy()
            .into_owned();
        let _ = std::fs::remove_dir_all(&dir);
        init_engine(dir, |_json| {});

        // Breaking Bad (tt0903747): a stable, default-add-on (Cinemeta) series. Same meta Load the
        // series page dispatches on open (no stream path yet — we just want the episode list).
        engine_dispatch(
            r#"{"field":"meta_details","action":{"action":"Load","args":{"model":"MetaDetails","args":{"metaPath":{"resource":"meta","type":"series","id":"tt0903747","extra":[]},"guessStream":true,"streamPath":null}}}}"#.to_owned(),
        );

        let mut md = String::from("null");
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            md = engine_get_state(r#""meta_details""#.to_owned());
            // Wait until the series meta has resolved with its episode list.
            if md.contains("\"videos\"") && md.contains("\"season\"") {
                break;
            }
        }
        println!("series meta_details ({} bytes): {}", md.len(), &md[..md.len().min(1200)]);

        // The series page's episode list reads these exact video fields (season/episode + id).
        assert!(md.contains("\"videos\""), "series meta must expose the videos (episodes) array");
        assert!(md.contains("\"season\""), "episodes carry a season number");
        assert!(md.contains("\"episode\""), "episodes carry an episode number");

        // Now open S1E1 (Breaking Bad S1E1 video id) the way openEpisode()/loadEpisodeStreams() does:
        // a MetaDetails Load with a stream path scoped to the episode's video id.
        engine_dispatch(
            r#"{"field":"meta_details","action":{"action":"Load","args":{"model":"MetaDetails","args":{"metaPath":{"resource":"meta","type":"series","id":"tt0903747","extra":[]},"guessStream":true,"streamPath":{"resource":"stream","type":"series","id":"tt0903747:1:1","extra":[]}}}}}"#.to_owned(),
        );

        let mut ep = String::from("null");
        for _ in 0..40 {
            std::thread::sleep(std::time::Duration::from_millis(500));
            ep = engine_get_state(r#""meta_details""#.to_owned());
            if ep.contains("\"streams\"") {
                break;
            }
        }
        println!("episode meta_details ({} bytes): {}", ep.len(), &ep[..ep.len().min(1200)]);

        // The episode stream list groups by the same per-add-on request.base as the movie page.
        assert!(ep.contains("\"streams\""), "episode meta_details must expose streams");
        assert!(
            ep.contains("\"base\"") && ep.contains("\"path\""),
            "every episode stream request exposes base (the per-add-on grouping key) + path"
        );
    }
}
