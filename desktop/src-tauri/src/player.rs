//! Embedded mpv (libmpv) player for the desktop app.
//!
//! WHY mpv on desktop. The frontend's first player was a webview `<video>` (see the old
//! `openPlayer` in src/main.ts): the OS WebView2/WebKitGTK pipeline plays plain H.264/AAC fine but
//! is unreliable for HEVC and Dolby Vision (no DV layer handling, spotty HEVC on Windows without the
//! paid HEVC extension). mpv is the same player the Apple apps use (libmpv / MPVKit there), so this
//! gives desktop the same broad-codec, DV-aware playback. We spawn the standalone `mpv` BINARY as a
//! child process (the Tauri/Rust twin of the macOS app's child-process model) and drive it over
//! mpv's JSON IPC, rather than linking libmpv directly. It keeps the bundle a plain executable drop
//! (mirroring how server.cjs + the node-* runtime are staged) and avoids a C-ABI/render-context
//! integration on three windowing systems.
//!
//! HONEST DV NOTE. mpv on desktop does DV-AWARE TONEMAPPING, NOT true Dolby Vision passthrough.
//! With `vo=gpu-next` + libplacebo, mpv reads the DV RPU and tonemaps the HDR image for the display;
//! it does not emit a DV bitstream to a DV-capable TV/monitor the way an AVPlayer/hardware DV path
//! would. So a DV title plays and looks right (HDR tonemapped), but this is not certified DV
//! passthrough. Document this expectation rather than implying parity with hardware DV.
//!
//! TORRENT GATE. This module is only ever handed a URL that is ALREADY playable: the frontend's
//! detail.ts runs the unchanged prepareTorrent -> resolveUrl pipeline (server.ts), which returns a
//! loopback `http://127.0.0.1:11470/<hash>/<idx>` URL ONLY after `isListening()` is true, and null
//! otherwise. `mpv_play` additionally refuses any loopback URL when the embedded server is not
//! listening, as a defensive backstop so a future caller can't bypass the gate.
//!
//! How it's wired: the frontend calls the `mpv_play` / `mpv_command` / `mpv_stop` Tauri commands
//! (see lib.rs). `mpv_play` spawns mpv bound to a borderless child window (`--wid=<handle>` when a
//! parent is available, else its own window) with an IPC server, waits for the socket, then sends
//! `loadfile`. Subsequent transport (pause/seek/quit) goes through `mpv_command`. The child is
//! force-killed on stop and on app exit so we never orphan an mpv process.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json::{json, Value};

/// Loopback host + port the embedded streaming server binds (see server.rs). Used only to recognize
/// a torrent/loopback URL so we can enforce the torrent gate before handing it to mpv. Kept in sync
/// with server.rs by intent; a drift here only weakens the defensive backstop, not the primary gate
/// (which lives in the TS resolveUrl pipeline).
const SERVER_HOST: &str = "127.0.0.1";
const SERVER_PORT: u16 = 11470;

/// How long to wait for mpv to create its IPC server socket after spawn before giving up. mpv opens
/// the socket within tens of ms once the process is up; this is a generous ceiling so a slow cold
/// start (first-run shader cache, AV scan) still connects.
const IPC_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Poll cadence while waiting for the socket to appear.
const IPC_CONNECT_POLL: Duration = Duration::from_millis(50);
/// Per-command IPC read/write timeout, so a wedged mpv can't hang a Tauri command thread forever.
const IPC_IO_TIMEOUT: Duration = Duration::from_millis(2000);

/// Observable player state surfaced to the frontend via `mpv_status`. An enum so illegal states
/// (e.g. "playing" with no child) are unrepresentable, matching server.rs's ServerState shape.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum PlayerState {
    /// No mpv running. `reason` is the last stop/idle detail, for diagnostics.
    Idle { reason: String },
    /// mpv spawned and the IPC socket is connected; transport commands will reach it.
    Playing,
    /// mpv failed to spawn or its IPC never came up. `reason` explains why, for the empty-state UI.
    Failed { reason: String },
}

/// The running mpv child plus the path to its IPC endpoint (unix socket / windows named pipe).
struct Player {
    child: Child,
    ipc_path: PathBuf,
}

static PLAYER: Lazy<Mutex<Option<Player>>> = Lazy::new(Default::default);
static STATE: Lazy<RwLock<PlayerState>> = Lazy::new(|| {
    RwLock::new(PlayerState::Idle {
        reason: "not started".to_owned(),
    })
});

fn set_state(state: PlayerState) {
    if let Ok(mut guard) = STATE.write() {
        *guard = state;
    }
}

/// Current player state, cloned for the Tauri command layer.
pub fn status() -> PlayerState {
    STATE
        .read()
        .ok()
        .map(|g| g.clone())
        .unwrap_or(PlayerState::Failed {
            reason: "status lock poisoned".to_owned(),
        })
}

/// The platform-tagged mpv binary name staged in `resources/` (mirrors server.rs's
/// `node_binary_name()` and the fetch script's per-platform staging). The real binary is dropped in
/// by the build step documented in scripts/fetch-server-deps.sh; keep these names in lockstep with
/// that script.
fn mpv_binary_name() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "mpv-darwin-arm64"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "mpv-darwin-x64"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "mpv-linux-x64"
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        "mpv-linux-arm64"
    }
    #[cfg(target_os = "windows")]
    {
        "mpv-win-x64.exe"
    }
}

/// Resolve the staged mpv binary path, preferring the bundled `resources/` copy and falling back to
/// a `mpv` already on PATH (handy for `tauri dev` before the binary is staged, and on Linux where a
/// system mpv is common). Returns the path to run, or None if neither is available.
fn resolve_mpv_binary(resource_dir: &Path) -> Option<PathBuf> {
    let bundled = resource_dir.join(mpv_binary_name());
    if bundled.exists() {
        return Some(bundled);
    }
    // PATH fallback: trust the OS to resolve a plain `mpv`/`mpv.exe`. We only return the bare name;
    // Command will search PATH. We can't cheaply prove it exists here, so callers treat a spawn
    // failure as "no mpv" via the Failed state.
    #[cfg(target_os = "windows")]
    let path_name = "mpv.exe";
    #[cfg(not(target_os = "windows"))]
    let path_name = "mpv";
    which_on_path(path_name).map(PathBuf::from)
}

/// Best-effort `which`: is `name` resolvable on PATH? Used only for the dev/system-mpv fallback.
fn which_on_path(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// A fresh, process-unique IPC endpoint path for mpv's `--input-ipc-server`. On Unix this is a unix
/// domain socket under the temp dir; on Windows it is a named pipe path (`\\.\pipe\...`), which mpv
/// expects there. A monotonic counter guarantees consecutive plays never collide on a stale path
/// (a wall-clock stamp alone can repeat for two calls within the same tick).
fn fresh_ipc_path() -> PathBuf {
    static SEQ: AtomicU64 = AtomicU64::new(0);
    let seq = SEQ.fetch_add(1, Ordering::Relaxed);
    let unique = format!("stremiox-mpv-{}-{}", std::process::id(), seq);
    #[cfg(target_os = "windows")]
    {
        // Named pipes are not filesystem paths; build the pipe name directly.
        PathBuf::from(format!(r"\\.\pipe\{unique}"))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::temp_dir().join(format!("{unique}.sock"))
    }
}

/// True if `url` targets the embedded loopback streaming server (a torrent file endpoint). Such URLs
/// are only playable once the server is listening; we use this to enforce the torrent gate as a
/// defensive backstop to the TS-side resolveUrl gate.
fn is_loopback_server_url(url: &str) -> bool {
    let needle_host = format!("//{SERVER_HOST}:{SERVER_PORT}/");
    let localhost = format!("//localhost:{SERVER_PORT}/");
    url.contains(&needle_host) || url.contains(&localhost)
}

/// Start mpv on `url` and load it over IPC. `resource_dir` locates the staged mpv binary; `wid` is an
/// optional native window handle to embed into (the Tauri main window's surface). When None, mpv
/// opens its own borderless window. `server_listening` is the backend's current view of the embedded
/// streaming server, used to enforce the torrent gate. Any previously running mpv is stopped first
/// (single-player model: one playback at a time, matching the single fullscreen player on Apple).
pub fn play(
    resource_dir: &Path,
    url: &str,
    wid: Option<isize>,
    server_listening: bool,
) -> Result<(), String> {
    // Validate the URL is one we will play: http(s) only. Reject anything else (file://, data:, etc.)
    // so a crafted stream URL can't point mpv at the local filesystem.
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("refusing to play a non-http(s) URL".to_owned());
    }

    // TORRENT GATE (defensive backstop). The primary gate is the TS resolveUrl pipeline, which only
    // yields a loopback URL once isListening() is true. Re-check here so a loopback URL can never be
    // played while the embedded server is down.
    if is_loopback_server_url(url) && !server_listening {
        return Err(
            "the embedded streaming server is not listening yet; torrent stream not ready".to_owned(),
        );
    }

    let mpv_bin = resolve_mpv_binary(resource_dir).ok_or_else(|| {
        format!(
            "mpv runtime missing ({}). Drop the mpv binary into resources/ (see fetch-server-deps.sh) or install mpv on PATH.",
            mpv_binary_name()
        )
    })?;

    // One player at a time: tear down any prior mpv before spawning a new one.
    stop();

    let ipc_path = fresh_ipc_path();
    let child = spawn_mpv(&mpv_bin, &ipc_path, wid).map_err(|e| {
        let reason = format!("failed to launch mpv: {e}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        reason
    })?;

    if let Ok(mut guard) = PLAYER.lock() {
        *guard = Some(Player {
            child,
            ipc_path: ipc_path.clone(),
        });
    }

    // Wait for the IPC socket, then loadfile. If the socket never appears, mpv almost certainly died
    // on startup (bad flag, missing GPU); surface that as Failed and clean up.
    if let Err(e) = wait_for_ipc(&ipc_path) {
        stop();
        let reason = format!("mpv IPC did not come up: {e}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        return Err(reason);
    }

    // `loadfile <url> replace` starts playback immediately (mpv was launched paused-less). Quoting is
    // handled by JSON encoding of the command array, so a URL with odd characters is safe.
    let load = json!({ "command": ["loadfile", url, "replace"] });
    if let Err(e) = send_ipc(&ipc_path, &load) {
        stop();
        let reason = format!("failed to load the stream in mpv: {e}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        return Err(reason);
    }

    set_state(PlayerState::Playing);
    Ok(())
}

/// Spawn the mpv child with the DV-aware, loopback-friendly flags. Returns the Child or an io::Error.
///
/// Flag rationale:
/// - `--input-ipc-server=<path>`  : the JSON IPC endpoint we drive transport through.
/// - `--vo=gpu-next` + `--gpu-api=auto` : libplacebo video output, the path that does DV-aware HDR
///   tonemapping (see the HONEST DV NOTE at the top). gpu-next is the modern default; auto picks the
///   best backend per OS (d3d11/vulkan/opengl).
/// - `--hwdec=auto-safe`          : hardware decode (HEVC/AV1) where the driver is known-good, which
///   is the whole reason for mpv over the webview on Windows.
/// - `--tone-mapping=bt.2390`     : a sane HDR->SDR tone curve for non-HDR displays.
/// - `--force-window=immediate` + `--keep-open=no` : show the window right away; exit playback (but
///   not the process, IPC stays up) at end of file.
/// - `--no-terminal` / `--really-quiet` : we own lifecycle via IPC, not a TTY.
/// - `--wid=<handle>`             : embed into the host window surface when one was provided.
fn spawn_mpv(mpv_bin: &Path, ipc_path: &Path, wid: Option<isize>) -> std::io::Result<Child> {
    let mut cmd = Command::new(mpv_bin);
    cmd.arg(format!("--input-ipc-server={}", ipc_path.to_string_lossy()))
        .arg("--vo=gpu-next")
        .arg("--gpu-api=auto")
        .arg("--hwdec=auto-safe")
        .arg("--tone-mapping=bt.2390")
        .arg("--force-window=immediate")
        .arg("--keep-open=no")
        .arg("--no-terminal")
        .arg("--really-quiet")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());

    if let Some(handle) = wid {
        // mpv reads --wid as the native parent (X11 Window / HWND / NSView pointer). Embedding keeps
        // playback inside the app window; without it mpv opens its own borderless window, which is a
        // fine fallback on platforms where embedding is unreliable.
        cmd.arg(format!("--wid={handle}"));
    }

    cmd.spawn()
}

/// Block until mpv's IPC endpoint is connectable, or the connect timeout elapses. Uses the same
/// transport (unix socket / windows named pipe) the command path uses, so "connectable" means "ready
/// to take commands".
fn wait_for_ipc(ipc_path: &Path) -> Result<(), String> {
    let deadline = Instant::now() + IPC_CONNECT_TIMEOUT;
    loop {
        if try_connect(ipc_path).is_ok() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("timed out waiting for the mpv IPC socket".to_owned());
        }
        std::thread::sleep(IPC_CONNECT_POLL);
    }
}

/// Send a single JSON IPC command to the running mpv and return its (best-effort) JSON reply. mpv
/// speaks newline-delimited JSON on the socket; we write one line and read one reply line. Errors if
/// no mpv is running or the socket I/O fails.
pub fn command(value: &Value) -> Result<Value, String> {
    let ipc_path = {
        let guard = PLAYER.lock().map_err(|_| "player lock poisoned".to_owned())?;
        match guard.as_ref() {
            Some(p) => p.ipc_path.clone(),
            None => return Err("no player is running".to_owned()),
        }
    };
    send_ipc(&ipc_path, value)
}

/// Force-kill the mpv child and reset state. Idempotent. Called on stop, on a failed play, and on
/// app exit so we never orphan an mpv process. Tries a graceful `quit` over IPC first, then kills.
pub fn stop() {
    let player = match PLAYER.lock() {
        Ok(mut guard) => guard.take(),
        Err(poisoned) => poisoned.into_inner().take(),
    };

    if let Some(mut player) = player {
        // Ask mpv to quit cleanly first so it can release the GPU/window; ignore failures (it may
        // already be dead). Then force-kill + reap to guarantee no orphan.
        let _ = send_ipc(&player.ipc_path, &json!({ "command": ["quit"] }));
        let _ = player.child.kill();
        let _ = player.child.wait();
        // Best-effort: drop the stale unix socket file (named pipes vanish with the process).
        #[cfg(not(target_os = "windows"))]
        {
            let _ = std::fs::remove_file(&player.ipc_path);
        }
    }

    set_state(PlayerState::Idle {
        reason: "stopped".to_owned(),
    });
}

// ---- IPC transport (platform-specific) ---------------------------------------------------------
//
// mpv's JSON IPC uses a unix domain socket on macOS/Linux and a named pipe on Windows. The std lib
// has no cross-platform abstraction for these, so each platform has a small connect helper; the
// request/response framing (one JSON line out, one line back) is shared.

/// Write one JSON command line and read one reply line over the IPC endpoint.
fn send_ipc(ipc_path: &Path, value: &Value) -> Result<Value, String> {
    let mut stream = try_connect(ipc_path)?;
    let mut line = serde_json::to_string(value).map_err(|e| format!("encode command: {e}"))?;
    line.push('\n');
    stream
        .write_all(line.as_bytes())
        .map_err(|e| format!("write IPC command: {e}"))?;
    stream.flush().map_err(|e| format!("flush IPC command: {e}"))?;
    read_reply(&mut stream)
}

/// Read newline-delimited JSON replies until we get one that is NOT an async event (mpv interleaves
/// `{"event":...}` notifications with command replies). Returns the first non-event JSON object, or
/// an empty object if the stream closes first.
fn read_reply(stream: &mut IpcStream) -> Result<Value, String> {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        let mut line = Vec::new();
        loop {
            match stream.read(&mut byte) {
                Ok(0) => {
                    // EOF: return whatever we have (or an empty object) so callers don't hang.
                    if line.is_empty() {
                        return Ok(json!({}));
                    }
                    break;
                }
                Ok(_) => {
                    if byte[0] == b'\n' {
                        break;
                    }
                    line.push(byte[0]);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // Read timeout hit: treat as "no synchronous reply" rather than an error, since
                    // fire-and-forget commands (loadfile) may not reply before the timeout.
                    return Ok(json!({}));
                }
                Err(e) => return Err(format!("read IPC reply: {e}")),
            }
        }
        let parsed: Value = match serde_json::from_slice(&line) {
            Ok(v) => v,
            Err(_) => continue, // skip an unparseable / partial line
        };
        // Skip async event notifications; we want the command's own reply.
        if parsed.get("event").is_some() {
            buf.push(parsed);
            continue;
        }
        return Ok(parsed);
    }
}

/// A connected IPC stream: a UnixStream on Unix, a File over the named pipe on Windows. Both
/// implement Read + Write, which is all the framing code needs.
#[cfg(not(target_os = "windows"))]
type IpcStream = std::os::unix::net::UnixStream;
#[cfg(target_os = "windows")]
type IpcStream = std::fs::File;

/// Connect to mpv's IPC endpoint with read/write timeouts applied, so a wedged mpv can't hang a
/// command thread. Returns a Read+Write stream on success.
#[cfg(not(target_os = "windows"))]
fn try_connect(ipc_path: &Path) -> Result<IpcStream, String> {
    let stream = std::os::unix::net::UnixStream::connect(ipc_path)
        .map_err(|e| format!("connect mpv IPC socket: {e}"))?;
    stream
        .set_read_timeout(Some(IPC_IO_TIMEOUT))
        .map_err(|e| format!("set IPC read timeout: {e}"))?;
    stream
        .set_write_timeout(Some(IPC_IO_TIMEOUT))
        .map_err(|e| format!("set IPC write timeout: {e}"))?;
    Ok(stream)
}

/// Windows: mpv exposes the IPC as a named pipe, which is opened like a file. We open it read+write.
/// Named pipes don't support std's socket timeouts, but mpv answers commands promptly; the connect
/// itself failing (pipe not yet created) is what the wait_for_ipc poll loop handles.
#[cfg(target_os = "windows")]
fn try_connect(ipc_path: &Path) -> Result<IpcStream, String> {
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(ipc_path)
        .map_err(|e| format!("open mpv IPC pipe: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_defaults_to_idle_before_play() {
        match status() {
            PlayerState::Idle { .. } => {}
            other => panic!("expected Idle before play, got {other:?}"),
        }
    }

    #[test]
    fn loopback_server_urls_are_recognized() {
        assert!(is_loopback_server_url(
            "http://127.0.0.1:11470/abcdef0123/0"
        ));
        assert!(is_loopback_server_url("http://localhost:11470/abc/1"));
        // A different host/port (a direct/debrid stream) is not gated as a loopback torrent URL.
        assert!(!is_loopback_server_url("https://cdn.example.com/movie.mkv"));
        assert!(!is_loopback_server_url("http://127.0.0.1:8080/other"));
    }

    #[test]
    fn play_rejects_non_http_urls() {
        let dir = std::env::temp_dir();
        for bad in [
            "file:///etc/passwd",
            "data:text/plain,hi",
            "ftp://example.com/x",
            "javascript:alert(1)",
        ] {
            let err = play(&dir, bad, None, true).unwrap_err();
            assert!(
                err.contains("non-http(s)"),
                "expected non-http rejection for {bad}, got: {err}"
            );
        }
    }

    #[test]
    fn play_enforces_the_torrent_gate_for_loopback_urls() {
        let dir = std::env::temp_dir();
        // server NOT listening -> a loopback (torrent) URL must be refused before any spawn.
        let err = play(&dir, "http://127.0.0.1:11470/deadbeef/0", None, false).unwrap_err();
        assert!(
            err.contains("not listening"),
            "expected torrent-gate rejection, got: {err}"
        );
    }

    #[test]
    fn mpv_binary_name_matches_the_host_target() {
        let name = mpv_binary_name();
        let known = [
            "mpv-darwin-arm64",
            "mpv-darwin-x64",
            "mpv-linux-x64",
            "mpv-linux-arm64",
            "mpv-win-x64.exe",
        ];
        assert!(known.contains(&name), "unexpected mpv binary name: {name}");
    }

    #[test]
    fn fresh_ipc_path_is_unique_and_platform_shaped() {
        let a = fresh_ipc_path();
        let b = fresh_ipc_path();
        assert_ne!(a, b, "consecutive IPC paths must differ");
        #[cfg(target_os = "windows")]
        assert!(a.to_string_lossy().starts_with(r"\\.\pipe\"));
        #[cfg(not(target_os = "windows"))]
        assert!(a.to_string_lossy().ends_with(".sock"));
    }

    /// `command()` with no running player returns an error rather than panicking.
    #[test]
    fn command_without_a_running_player_errors() {
        // Ensure no player is parked from another test.
        stop();
        let err = command(&json!({ "command": ["get_property", "pause"] })).unwrap_err();
        assert!(err.contains("no player is running"), "got: {err}");
    }
}
