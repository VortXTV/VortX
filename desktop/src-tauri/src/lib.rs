// StremioX desktop app logic. The shared stremio-core engine embeds directly in the Tauri backend
// (Rust↔Rust, no FFI). This file owns the Runtime (like the Apple core's lib.rs) and exposes it to
// the frontend through Tauri commands + an event channel, instead of a C ABI:
//   * `.setup()` hydrates persisted buckets from the OS app-data dir, builds the Runtime, and spawns
//     the event loop, which emits each RuntimeEvent to the frontend as a `core-event`.
//   * `engine_dispatch(action_json)` dispatches a `{ field?, action }` to the Runtime.
//   * `engine_get_state(field_json)` returns a model field as JSON.
// On top of this, the mpv (libmpv) player lands as a spawned child process driven over private JSON
// IPC (see player.rs), exposed through `mpv_play`, typed pause/seek, `mpv_stop`, and `mpv_status`.
// Native playback is currently Unix + exact numeric-loopback torrent URLs only. Remote media stays
// in the platform-verifying webview until the bundled mpv runtime is attested; Windows stays
// disabled until its named-pipe IPC can enforce bounded reads.

mod child_supervisor {
    use std::io::{Read, Write};
    use std::path::Path;
    use std::process::{Child, ChildStdin, Command, ExitStatus, Stdio};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::time::Duration;

    const MODE_ENV: &str = "VORTX_CHILD_SUPERVISOR";
    const PROGRAM_ENV: &str = "VORTX_CHILD_PROGRAM";
    const ARGS_ENV: &str = "VORTX_CHILD_ARGS_JSON";
    const START_BYTE: u8 = 1;
    const MAX_PRIVATE_ENV_BYTES: usize = 16 * 1024;
    const POLL_INTERVAL: Duration = Duration::from_millis(25);

    /// A same-binary helper process plus the parent's write end of its ownership pipe. The helper is
    /// the target process's direct parent. Closing `control` means the Tauri owner disappeared; the
    /// helper then kills and waits for the target before it exits.
    pub(crate) struct SupervisedChild {
        process: Child,
        control: Option<ChildStdin>,
        start_payload: Option<Vec<u8>>,
        started: bool,
        reaped: bool,
    }

    impl SupervisedChild {
        /// Configure the current executable to enter supervisor mode and launch `program`. Callers
        /// may add target environment, current directory, and stdout/stderr to this Command; the
        /// helper passes those inherited settings to its target.
        pub(crate) fn command(program: &Path, args: &[String]) -> std::io::Result<Command> {
            let encoded_args = serde_json::to_string(args)
                .map_err(|error| std::io::Error::other(format!("encode child args: {error}")))?;
            let mut command = Command::new(std::env::current_exe()?);
            command
                .env(MODE_ENV, "1")
                .env(PROGRAM_ENV, program)
                .env(ARGS_ENV, encoded_args);
            Ok(command)
        }

        /// Spawn a configured supervisor and retain its ownership-pipe writer. Failure to obtain the
        /// writer kills and reaps the helper immediately, because a helper without that pipe cannot
        /// prove or observe parent ownership.
        pub(crate) fn spawn(command: Command) -> std::io::Result<Self> {
            Self::spawn_with_private_env(command, &[])
        }

        /// Configure private target-only environment without placing its values in the helper's
        /// process environment. The payload crosses the ownership pipe only after parking and is
        /// applied to the target Command immediately before spawn.
        pub(crate) fn spawn_with_private_env(
            mut command: Command,
            private_env: &[(&str, &str)],
        ) -> std::io::Result<Self> {
            let start_payload = serde_json::to_vec(private_env)
                .map_err(|error| std::io::Error::other(format!("encode private env: {error}")))?;
            if start_payload.len() > MAX_PRIVATE_ENV_BYTES {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "child supervisor private environment is too large",
                ));
            }
            command.stdin(Stdio::piped());
            let mut process = command.spawn()?;
            let Some(control) = process.stdin.take() else {
                let _ = process.kill();
                let _ = process.wait();
                return Err(std::io::Error::other(
                    "child supervisor ownership pipe unavailable",
                ));
            };
            Ok(Self {
                process,
                control: Some(control),
                start_payload: Some(start_payload),
                started: false,
                reaped: false,
            })
        }

        /// Authorize target launch only after this supervisor has been parked in app-owned state.
        /// EOF before this byte makes the helper exit without ever spawning the target.
        pub(crate) fn start(&mut self) -> std::io::Result<()> {
            if self.started {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::AlreadyExists,
                    "child supervisor already started",
                ));
            }
            let control = self.control.as_mut().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "child supervisor ownership pipe unavailable",
                )
            })?;
            let payload = self.start_payload.take().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::BrokenPipe,
                    "child supervisor start payload unavailable",
                )
            })?;
            let payload_len = u32::try_from(payload.len()).map_err(|_| {
                std::io::Error::new(
                    std::io::ErrorKind::InvalidInput,
                    "child supervisor private environment is too large",
                )
            })?;
            control.write_all(&[START_BYTE])?;
            control.write_all(&payload_len.to_be_bytes())?;
            control.write_all(&payload)?;
            control.flush()?;
            self.started = true;
            Ok(())
        }

        pub(crate) fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
            let status = self.process.try_wait()?;
            if status.is_some() {
                self.reaped = true;
            }
            Ok(status)
        }

        #[cfg(test)]
        pub(crate) fn id(&self) -> u32 {
            self.process.id()
        }

        /// Signal intentional owner exit and wait until the helper has killed and reaped its target.
        /// Test-only unsupervised handles have no pipe, so they retain the old direct kill fallback.
        pub(crate) fn shutdown_and_wait(mut self) {
            self.shutdown_inner();
        }

        fn shutdown_inner(&mut self) {
            if self.reaped {
                return;
            }
            if self.control.take().is_none() {
                let _ = self.process.kill();
            }
            let _ = self.process.wait();
            self.reaped = true;
        }

        #[cfg(test)]
        pub(crate) fn unsupervised(process: Child) -> Self {
            Self {
                process,
                control: None,
                start_payload: None,
                started: true,
                reaped: false,
            }
        }
    }

    impl Drop for SupervisedChild {
        fn drop(&mut self) {
            self.shutdown_inner();
        }
    }

    /// Enter helper mode when this invocation was created by `SupervisedChild::command`. This check
    /// runs before Tauri initializes, so helper processes never open a window or start app services.
    pub(crate) fn run_if_requested() -> bool {
        if std::env::var(MODE_ENV).as_deref() != Ok("1") {
            return false;
        }
        run_target_from_environment();
        true
    }

    fn run_target_from_environment() {
        let Some(program) = std::env::var_os(PROGRAM_ENV) else {
            return;
        };
        let Ok(encoded_args) = std::env::var(ARGS_ENV) else {
            return;
        };
        let Ok(args) = serde_json::from_str::<Vec<String>>(&encoded_args) else {
            return;
        };

        // The target may not start until its Tauri owner has parked this helper and explicitly sent
        // GO. If the owner dies first, EOF arrives here and no target process is ever created.
        let mut stdin = std::io::stdin();
        let mut start = [0u8; 1];
        if stdin.read_exact(&mut start).is_err() || start[0] != START_BYTE {
            return;
        }
        let mut encoded_len = [0u8; 4];
        if stdin.read_exact(&mut encoded_len).is_err() {
            return;
        }
        let private_env_len = u32::from_be_bytes(encoded_len) as usize;
        if private_env_len > MAX_PRIVATE_ENV_BYTES {
            return;
        }
        let mut encoded_private_env = vec![0u8; private_env_len];
        if stdin.read_exact(&mut encoded_private_env).is_err() {
            return;
        }
        let Ok(private_env) = serde_json::from_slice::<Vec<(String, String)>>(&encoded_private_env)
        else {
            return;
        };
        if private_env.iter().any(|(name, _)| {
            name.is_empty()
                || name.contains('=')
                || matches!(name.as_str(), MODE_ENV | PROGRAM_ENV | ARGS_ENV)
        }) {
            return;
        }

        let mut command = Command::new(program);
        command
            .args(args)
            .env_remove(MODE_ENV)
            .env_remove(PROGRAM_ENV)
            .env_remove(ARGS_ENV)
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        command.envs(private_env);
        let Ok(mut target) = command.spawn() else {
            return;
        };
        drop(command);
        drop(encoded_private_env);

        let owner_gone = Arc::new(AtomicBool::new(false));
        let reader_flag = Arc::clone(&owner_gone);
        if std::thread::Builder::new()
            .name("vortx-child-owner-watch".to_owned())
            .spawn(move || {
                let mut stdin = std::io::stdin().lock();
                let mut byte = [0u8; 1];
                loop {
                    match stdin.read(&mut byte) {
                        Ok(0) => break,
                        Ok(_) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(_) => break,
                    }
                }
                reader_flag.store(true, Ordering::SeqCst);
            })
            .is_err()
        {
            let _ = target.kill();
            let _ = target.wait();
            return;
        }

        loop {
            if owner_gone.load(Ordering::SeqCst) {
                let _ = target.kill();
                let _ = target.wait();
                return;
            }
            match target.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) => std::thread::sleep(POLL_INTERVAL),
                Err(_) => {
                    let _ = target.kill();
                    let _ = target.wait();
                    return;
                }
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::path::PathBuf;
        use std::time::Instant;

        const CASE_ENV: &str = "VORTX_SUPERVISOR_TEST_CASE";
        const READY_ENV: &str = "VORTX_SUPERVISOR_TEST_READY";
        const RECEIPT_ENV: &str = "VORTX_SUPERVISOR_TEST_RECEIPT";
        const HELPER_PID_ENV: &str = "VORTX_SUPERVISOR_TEST_HELPER_PID";
        const TARGET_PID_ENV: &str = "VORTX_SUPERVISOR_TEST_TARGET_PID";
        const PRIVATE_ENV: &str = "VORTX_SUPERVISOR_TEST_PRIVATE";

        fn harness_args(test_name: &str) -> Vec<String> {
            vec![
                "--ignored".to_owned(),
                "--exact".to_owned(),
                test_name.to_owned(),
                "--nocapture".to_owned(),
            ]
        }

        fn wait_for_file(path: &Path, timeout: Duration) -> bool {
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                if path.exists() {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            path.exists()
        }

        fn process_is_alive(pid: u32) -> bool {
            #[cfg(not(target_os = "windows"))]
            {
                Command::new("kill")
                    .args(["-0", &pid.to_string()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .map(|status| status.success())
                    .unwrap_or(false)
            }
            #[cfg(target_os = "windows")]
            {
                Command::new("tasklist")
                    .args(["/FI", &format!("PID eq {pid}"), "/NH"])
                    .output()
                    .map(|output| {
                        String::from_utf8_lossy(&output.stdout).contains(&pid.to_string())
                    })
                    .unwrap_or(false)
            }
        }

        fn read_pid(path: &Path) -> u32 {
            std::fs::read_to_string(path)
                .expect("read process id")
                .trim()
                .parse()
                .expect("parse process id")
        }

        fn wait_for_process_exit(pid: u32, timeout: Duration) -> bool {
            let deadline = Instant::now() + timeout;
            while Instant::now() < deadline {
                if !process_is_alive(pid) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
            !process_is_alive(pid)
        }

        fn run_parent_death_case(case: &str) {
            let directory = tempfile::tempdir().expect("supervisor test directory");
            let ready = directory.path().join("ready");
            let receipt = directory.path().join("reaped");
            let helper_pid = directory.path().join("helper.pid");
            let target_pid = directory.path().join("target.pid");
            let executable = std::env::current_exe().expect("current test executable");
            let mut surrogate = Command::new(executable)
                .args(harness_args(
                    "child_supervisor::tests::supervisor_surrogate_entry",
                ))
                .env(CASE_ENV, case)
                .env(READY_ENV, &ready)
                .env(RECEIPT_ENV, &receipt)
                .env(HELPER_PID_ENV, &helper_pid)
                .env(TARGET_PID_ENV, &target_pid)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn surrogate parent");

            let ready_in_time = wait_for_file(&ready, Duration::from_secs(5));
            let _ = surrogate.kill();
            let _ = surrogate.wait();
            assert!(
                ready_in_time,
                "surrogate did not reach the {case} checkpoint"
            );
            assert!(
                wait_for_file(&receipt, Duration::from_secs(5)),
                "supervisor did not finish target cleanup for {case}"
            );

            let helper = read_pid(&helper_pid);
            assert!(
                wait_for_process_exit(helper, Duration::from_secs(5)),
                "supervisor must exit after owner death ({case})"
            );
            if case == "before-go" {
                assert!(
                    !target_pid.exists(),
                    "EOF before GO must exit without spawning the target"
                );
            } else {
                let target = read_pid(&target_pid);
                assert!(
                    !process_is_alive(target),
                    "EOF after GO must kill and wait the direct target"
                );
            }
        }

        #[test]
        fn owner_death_before_and_after_go_cannot_orphan_a_target() {
            run_parent_death_case("before-go");
            run_parent_death_case("after-go");
        }

        #[test]
        #[ignore]
        fn supervisor_surrogate_entry() {
            let case = std::env::var(CASE_ENV).expect("supervisor test case");
            let ready = PathBuf::from(std::env::var_os(READY_ENV).expect("ready path"));
            let helper_pid =
                PathBuf::from(std::env::var_os(HELPER_PID_ENV).expect("helper pid path"));
            let target_pid =
                PathBuf::from(std::env::var_os(TARGET_PID_ENV).expect("target pid path"));
            let executable = std::env::current_exe().expect("current test executable");
            let target_args = harness_args("child_supervisor::tests::supervised_target_entry");
            let mut command =
                SupervisedChild::command(&executable, &target_args).expect("supervisor command");
            command
                .args(harness_args(
                    "child_supervisor::tests::supervisor_watchdog_entry",
                ))
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            let mut supervisor =
                SupervisedChild::spawn_with_private_env(command, &[(PRIVATE_ENV, "target-only")])
                    .expect("spawn supervisor");
            std::fs::write(&helper_pid, supervisor.id().to_string()).expect("write helper pid");

            if case == "after-go" {
                supervisor.start().expect("send supervisor GO");
                assert!(
                    wait_for_file(&target_pid, Duration::from_secs(5)),
                    "supervised target did not start"
                );
            }
            std::fs::write(&ready, b"parked").expect("write ready checkpoint");

            let _keep_owner_and_pipe_alive = supervisor;
            loop {
                std::thread::sleep(Duration::from_secs(60));
            }
        }

        #[test]
        #[ignore]
        fn supervisor_watchdog_entry() {
            assert!(
                run_if_requested(),
                "watchdog entry requires supervisor mode"
            );
            let receipt =
                PathBuf::from(std::env::var_os(RECEIPT_ENV).expect("cleanup receipt path"));
            std::fs::write(receipt, b"target reaped").expect("write cleanup receipt");
        }

        #[test]
        #[ignore]
        fn supervised_target_entry() {
            assert_eq!(
                std::env::var(PRIVATE_ENV).as_deref(),
                Ok("target-only"),
                "private start payload must reach only the supervised target"
            );
            let target_pid =
                PathBuf::from(std::env::var_os(TARGET_PID_ENV).expect("target pid path"));
            std::fs::write(target_pid, std::process::id().to_string()).expect("write target pid");
            loop {
                std::thread::sleep(Duration::from_secs(60));
            }
        }
    }
}

mod engine;
mod model;
mod player;
mod server;

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

static RUNTIME: Lazy<RwLock<Option<Runtime<DesktopEnv, DesktopModel>>>> =
    Lazy::new(Default::default);

/// Build the engine: hydrate persisted buckets from `storage_dir`, construct the Runtime, and spawn
/// the event loop that forwards every RuntimeEvent (as JSON) to `on_event`. Mirrors the Apple core's
/// `stremiox_core_init` (and stremio-core-web's `initialize_runtime`). Idempotent.
fn init_engine<F: Fn(String) + Send + Sync + 'static>(storage_dir: String, on_event: F) {
    if RUNTIME.read().ok().map(|g| g.is_some()).unwrap_or(true) {
        return; // already initialized (or lock poisoned; don't re-init)
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
    let streams = streams
        .ok()
        .flatten()
        .unwrap_or_else(|| StreamsBucket::new(profile.uid()));
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

    // Forward mpv playback position to the engine Player so Continue Watching + resume work on desktop
    // (the previously-missing leg: desktop played but never reported a position). Backend wiring only;
    // the frontend's engine-driven playback supplies the loaded Player this updates.
    player::set_progress_sink(Box::new(report_progress));
    player::start_progress_reporter();
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
fn dispatch_action_json(action_json: &str) {
    let dto: ActionDto = match serde_json::from_str(action_json) {
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

/// Dispatch an action (JSON) to the Runtime. No-op if not initialized or the JSON is invalid.
#[tauri::command]
fn engine_dispatch(action_json: String) {
    dispatch_action_json(&action_json);
}

/// Forward a desktop playback position to the engine Player (ms), so Continue Watching + resume reflect
/// it. Mirrors the Apple core's reportProgress (Player -> TimeChanged). Registered as the player's
/// progress sink at init; the engine ignores it unless a Player is loaded, so it is safe to call on
/// every sample while mpv is playing.
fn report_progress(time_ms: u64, duration_ms: u64) {
    let action = format!(
        r#"{{"field":"player","action":{{"action":"Player","args":{{"action":"TimeChanged","args":{{"time":{time_ms},"duration":{duration_ms},"device":"desktop"}}}}}}}}"#
    );
    dispatch_action_json(&action);
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
/// streams only after the current child passes owner-authenticated readiness.
#[tauri::command]
fn server_status() -> server::ServerState {
    server::status()
}

/// The base URL of the embedded streaming server (`http://127.0.0.1:11470`). The frontend builds the
/// torrent prime (`POST <base>/<infohash>/create`) and play (`<base>/<infohash>/<fileIdx>`) URLs from
/// this, the StremioServer-equivalent on desktop.
#[tauri::command]
fn server_base_url() -> String {
    server::base_url()
}

/// Whether the currently managed embedded-server child is ready. This is a bounded HMAC
/// challenge-response using a fresh per-child key, not a bare connection to whatever owns the port.
/// The frontend polls this before constructing or falling back to any loopback media URL.
#[tauri::command]
fn server_is_listening() -> bool {
    server::is_listening()
}

// ---- mpv player commands -----------------------------------------------------------------------

/// Play an exact `http://127.0.0.1:11470/<40-hex-hash>/<u32-index>` torrent URL in the embedded mpv
/// player. Remote HTTP(S), localhost aliases, other loopback forms/routes, queries, and Windows
/// native playback fail closed here. The TORRENT GATE is enforced twice: primarily by resolveUrl
/// (which returns null until `isListening()`), and again here by passing owner-authenticated server
/// readiness into `player::play`.
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
    // Owner-authenticated readiness for the defensive torrent-gate backstop in player::play.
    let server_listening = server::is_listening();
    // Try to embed mpv into the main window's native surface. A failure to resolve a handle is not
    // fatal, mpv falls back to its own borderless window.
    let wid = main_window_handle(&app);
    player::play(&resource_dir, &url, wid, server_listening)
}

/// Pause/resume through a typed boundary. The webview cannot issue arbitrary mpv IPC.
#[tauri::command]
fn mpv_set_paused(paused: bool) -> Result<(), String> {
    player::set_paused(paused)
}

/// Relative seek through a finite, bounded typed boundary.
#[tauri::command]
fn mpv_seek_relative(seconds: f64) -> Result<(), String> {
    player::seek_relative(seconds)
}

/// Stop playback and close the parked supervisor pipe; its direct mpv target is killed and reaped.
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
    if child_supervisor::run_if_requested() {
        return;
    }

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
            // streams play. Each child must pass the private owner challenge before the frontend can
            // use it. Resources are staged next to the binary by fetch-server-deps.sh and bundled via
            // tauri.conf.json; the server uses a writable cache dir as its HOME.
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
            mpv_set_paused,
            mpv_seek_relative,
            mpv_stop,
            mpv_status
        ])
        .build(tauri::generate_context!())
        .expect("error while running the StremioX desktop app")
        .run(|_app_handle, event| {
            // Close both supervisor ownership pipes on ordinary exit. Crash and SIGKILL close the
            // same OS handles automatically, so each helper kills and waits its direct target.
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
        println!(
            "board state ({} bytes): {}",
            board.len(),
            &board[..board.len().min(800)]
        );
        assert!(
            board.contains("\"poster\""),
            "board should populate with real catalog items (posters) from the default add-ons"
        );
    }

    /// Contract test for the desktop **detail page** (src/detail.ts + streamRanking.ts): load
    /// `meta_details` for a known movie the same way the frontend does, and assert the JSON carries
    /// the exact fields the detail UI reads: the per-add-on `streams[].request.base` grouping key,
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
        println!(
            "meta_details ({} bytes): {}",
            md.len(),
            &md[..md.len().min(1200)]
        );

        // The detail page parses these exact keys; if the engine ever renames them the UI breaks.
        assert!(
            md.contains("\"metaItems\""),
            "meta_details must expose metaItems"
        );
        assert!(
            md.contains("\"streams\""),
            "meta_details must expose streams"
        );
        assert!(
            md.contains("\"links\""),
            "meta carries links (genres + imdb rating)"
        );
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
        // series page dispatches on open (no stream path yet; we just want the episode list).
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
        println!(
            "series meta_details ({} bytes): {}",
            md.len(),
            &md[..md.len().min(1200)]
        );

        // The series page's episode list reads these exact video fields (season/episode + id).
        assert!(
            md.contains("\"videos\""),
            "series meta must expose the videos (episodes) array"
        );
        assert!(md.contains("\"season\""), "episodes carry a season number");
        assert!(
            md.contains("\"episode\""),
            "episodes carry an episode number"
        );

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
        println!(
            "episode meta_details ({} bytes): {}",
            ep.len(),
            &ep[..ep.len().min(1200)]
        );

        // The episode stream list groups by the same per-add-on request.base as the movie page.
        assert!(
            ep.contains("\"streams\""),
            "episode meta_details must expose streams"
        );
        assert!(
            ep.contains("\"base\"") && ep.contains("\"path\""),
            "every episode stream request exposes base (the per-add-on grouping key) + path"
        );
    }
}
