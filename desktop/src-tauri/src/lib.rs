// VortX desktop shell. The window runs the VortX web client (web.vortx.tv); this backend adds what a
// browser cannot have, exposed to that origin only (capabilities/default.json):
//   * the VortX streaming server, in process on an ephemeral loopback port (server.rs), so torrent
//     sources play; `server_base_url` / `server_status` report it to the web client;
//   * the mpv (libmpv) player as a spawned child process driven over private JSON IPC (player.rs),
//     exposed through `mpv_play`, typed pause/seek, `mpv_stop` and `mpv_status`, with its position
//     emitted as `vortx://player-progress` events for Continue Watching.
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

mod player;
mod server;

use serde::Serialize;
use tauri::{Emitter, Manager};

/// The playback position the shell reports to the web client every few seconds while mpv plays.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlayerProgress {
    position_ms: u64,
    duration_ms: u64,
}

/// The in-process streaming server's state (`running` / `failed` + reason / `disabled`).
#[tauri::command]
fn server_status() -> server::ServerState {
    server::status()
}

/// The streaming server's loopback base URL (`http://127.0.0.1:<port>`). The web client builds the
/// torrent prime (`POST <base>/<infohash>/create`) and file (`<base>/<infohash>/<fileIdx>`) URLs from
/// it. Errors while the server is not running, so the client keeps torrents unplayable.
#[tauri::command]
fn server_base_url() -> Result<String, String> {
    server::base_url().ok_or_else(|| "the streaming server is not running".to_owned())
}

// ---- mpv player commands -----------------------------------------------------------------------

/// Play an exact `http://127.0.0.1:<bound-port>/<40-hex-hash>/<u32-index>` torrent URL in the embedded
/// mpv player, optionally resuming at `start` seconds. Remote HTTP(S), other loopback forms/routes,
/// queries and Windows native playback fail closed here; the web client then uses its in-page player.
///
/// mpv is embedded into the app's main window surface when a native handle is available, so playback
/// stays inside the app; otherwise mpv opens its own window.
#[tauri::command]
fn mpv_play(app: tauri::AppHandle, url: String, start: Option<f64>) -> Result<(), String> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| format!("resource dir unavailable: {e}"))?;
    let authority = server::authority();
    let wid = main_window_handle(&app);
    player::play(&resource_dir, &url, wid, authority.as_deref(), start)
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

/// The player's current state (`playing` / `idle` / `failed` + reason), for the overlay's state line.
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
            // Start the in-process streaming server on loopback so torrent sources play. Its settings
            // and piece cache live in the OS cache dir.
            let data_dir = app
                .path()
                .app_cache_dir()
                .unwrap_or_else(|_| std::env::temp_dir().join("vortx-desktop"))
                .join("streaming-server");
            server::start(&data_dir);

            // Hand mpv's position to the web client, which records Continue Watching and resume through
            // the VortX account exactly like its in-page player.
            let handle = app.handle().clone();
            player::set_progress_sink(Box::new(move |position_ms, duration_ms| {
                let _ = handle.emit(
                    "vortx://player-progress",
                    PlayerProgress {
                        position_ms,
                        duration_ms,
                    },
                );
            }));
            player::start_progress_reporter();
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            server_status,
            server_base_url,
            mpv_play,
            mpv_set_paused,
            mpv_seek_relative,
            mpv_stop,
            mpv_status
        ])
        .build(tauri::generate_context!())
        .expect("error while running the VortX desktop app")
        .run(|_app_handle, event| {
            // Close the player's supervisor ownership pipe and stop the server on ordinary exit. Crash and
            // SIGKILL close the same OS handles automatically, so the helper kills and waits mpv.
            if let tauri::RunEvent::Exit = event {
                player::stop();
                server::stop();
            }
        });
}
