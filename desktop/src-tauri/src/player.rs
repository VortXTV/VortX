//! Embedded mpv (libmpv) player for the desktop app.
//!
//! WHY mpv on desktop. The frontend's first player was a webview `<video>` (see the old
//! `openPlayer` in src/main.ts): the OS WebView2/WebKitGTK pipeline plays plain H.264/AAC fine but
//! is unreliable for HEVC and Dolby Vision (no DV layer handling, spotty HEVC on Windows without the
//! paid HEVC extension). mpv is the same player the Apple apps use (libmpv / MPVKit there), so this
//! gives desktop the same broad-codec, DV-aware playback. We spawn the standalone `mpv` BINARY as a
//! child process (the Tauri/Rust twin of the macOS app's child-process model) and drive it over
//! mpv's JSON IPC, rather than linking libmpv directly. The current secure path is deliberately
//! narrower: native playback accepts only the exact numeric-loopback torrent route on Unix. Remote
//! media stays in the platform webview until the bundled runtime is attested, and Windows native
//! playback stays disabled until named-pipe reads can be bounded.
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
//! otherwise. `mpv_play` additionally refuses the URL until the embedded server passes its
//! owner-authenticated health challenge, as a defensive backstop so a different process merely
//! holding the port cannot satisfy the gate.
//!
//! How it's wired: the frontend calls the `mpv_play` / typed transport / `mpv_stop` Tauri commands
//! (see lib.rs). `mpv_play` spawns mpv bound to a borderless child window (`--wid=<handle>` when a
//! parent is available, else its own window) with an IPC server, waits for the socket, then sends
//! `loadfile`. Subsequent pause/seek transport goes through narrow Rust commands. A same-binary
//! supervisor owns mpv directly: explicit stop closes its ownership pipe, and app crash or SIGKILL
//! produces the same EOF, so the helper kills and waits mpv before exiting. A generation-owned
//! monitor also corrects `Playing` if mpv crashes on its own.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde::Serialize;
use serde_json::{json, Value};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

use crate::child_supervisor::SupervisedChild;

/// Loopback host + port the embedded streaming server binds (see server.rs). Used only to recognize
/// a torrent/loopback URL so we can enforce the torrent gate before handing it to mpv. Kept in sync
/// with server.rs by intent; a drift here only weakens the defensive backstop, not the primary gate
/// (which lives in the TS resolveUrl pipeline).
const SERVER_AUTHORITY: &str = "127.0.0.1:11470";

/// How long to wait for mpv to create its IPC server socket after spawn before giving up. mpv opens
/// the socket within tens of ms once the process is up; this is a generous ceiling so a slow cold
/// start (first-run shader cache, AV scan) still connects.
const IPC_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Poll cadence while waiting for the socket to appear.
const IPC_CONNECT_POLL: Duration = Duration::from_millis(50);
/// Per-command IPC read/write timeout, so a wedged mpv can't hang a Tauri command thread forever.
const IPC_IO_TIMEOUT: Duration = Duration::from_millis(2000);
/// One command may receive async events before its reply, but the entire exchange is capped so a
/// peer cannot stream unbounded data into memory.
const IPC_RESPONSE_LIMIT: usize = 64 * 1024;

/// App-owned media trust policy. These arguments are passed after ordinary playback tuning and are
/// never sourced from user configuration. If a packaged mpv does not recognize one, mpv exits
/// instead of silently continuing with unknown certificate behavior.
const REQUIRED_MPV_SECURITY_ARGS: [&str; 7] = [
    "--no-config",
    "--load-scripts=no",
    "--resume-playback=no",
    "--tls-verify=yes",
    "--stream-lavf-o=tls_verify=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7",
    "--demuxer-lavf-o=tls_verify=1",
    "--demuxer-lavf-propagate-opts=yes",
];

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
    supervisor: Arc<Mutex<Option<SupervisedChild>>>,
    generation: u64,
    ipc_path: PathBuf,
    /// Owns and removes the securely-created Unix IPC directory. Windows named pipes have no
    /// filesystem directory, so this remains None there.
    _ipc_directory: Option<tempfile::TempDir>,
}

static PLAYER: Lazy<Mutex<Option<Player>>> = Lazy::new(Default::default);
/// Serializes the complete native play/stop transition, including helper spawn, parking, IPC
/// readiness, error cleanup, and teardown. Recovering poison preserves ownership after a panic.
static PLAYER_LIFECYCLE: Lazy<Mutex<()>> = Lazy::new(Default::default);
static NEXT_PLAYER_GENERATION: AtomicU64 = AtomicU64::new(1);
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

// ---- Playback-progress reporting (Continue Watching / resume) -----------------------------------
//
// Desktop used to play but never tell the engine where the user was, so Continue Watching and resume
// never reflected desktop playback. This samples mpv's position over the IPC we already have and
// forwards it to the engine Player as a `TimeChanged` action (the same report the Apple apps send).
// player.rs stays decoupled from the runtime: lib.rs registers a sink closure at init.

/// Forwards a sampled position (time_ms, duration_ms) to the engine. None until lib.rs registers it.
type ProgressSink = Box<dyn Fn(u64, u64) + Send + Sync>;
static PROGRESS_SINK: Lazy<RwLock<Option<ProgressSink>>> = Lazy::new(Default::default);
/// Guards the single long-lived reporter thread so it is spawned at most once.
static REPORTER_STARTED: AtomicBool = AtomicBool::new(false);
/// Sampling cadence. Continue Watching only needs a coarse position; a tight loop would spam the
/// engine (and the IPC). Matches the Apple apps' periodic report, not a per-frame update.
const PROGRESS_POLL: Duration = Duration::from_secs(5);

/// Register the engine progress sink. Called once from lib.rs at engine init.
pub fn set_progress_sink(sink: ProgressSink) {
    if let Ok(mut guard) = PROGRESS_SINK.write() {
        *guard = Some(sink);
    }
}

/// Start the single background thread that, while mpv is Playing, samples its position every
/// `PROGRESS_POLL` and forwards it to the engine. Idempotent (a second call is a no-op).
pub fn start_progress_reporter() {
    if REPORTER_STARTED.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(|| loop {
        std::thread::sleep(PROGRESS_POLL);
        if matches!(status(), PlayerState::Playing) {
            report_position_now();
        }
    });
}

/// Sample mpv once and forward the position to the sink. A no-op when nothing is playing, the position
/// is still null during load, or the duration is unknown (so a 0-duration report never lands).
fn report_position_now() {
    let Some((time_ms, duration_ms)) = read_position_ms() else {
        return;
    };
    if duration_ms == 0 {
        return;
    }
    if let Ok(guard) = PROGRESS_SINK.read() {
        if let Some(sink) = guard.as_ref() {
            sink(time_ms, duration_ms);
        }
    }
}

/// mpv's current position and duration in milliseconds, or None if unavailable (no player, not yet
/// started, or a property still null during load).
fn read_position_ms() -> Option<(u64, u64)> {
    let time = get_property_f64("time-pos")?;
    let duration = get_property_f64("duration")?;
    if time < 0.0 || duration <= 0.0 {
        return None;
    }
    Some(((time * 1000.0) as u64, (duration * 1000.0) as u64))
}

/// Fetch a single numeric mpv property over IPC. None when no player runs or the property is
/// absent/null (e.g. queried before the file is loaded). Each call uses its own short-lived IPC
/// connection, so it never contends with the transport command path beyond mpv's own multiplexing.
fn get_property_f64(name: &str) -> Option<f64> {
    let reply = command(&json!({ "command": ["get_property", name] })).ok()?;
    reply.get("data").and_then(Value::as_f64)
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

/// The platform-tagged mpv path under `resources/` (mirrors server.rs's `node_binary_name()` and the
/// fetch script's per-platform staging). Keep these in lockstep with scripts/fetch-server-deps.sh.
/// On Windows/Linux the staged artifact is a single self-contained binary; on macOS mpv is dynamically
/// linked, so the fetch script stages the whole self-contained `mpv.app` and this returns the path to
/// its inner executable (the bundle's dylibs resolve via @executable_path, so spawning it directly works).
fn mpv_binary_name() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "mpv-darwin-arm64.app/Contents/MacOS/mpv"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "mpv-darwin-x64.app/Contents/MacOS/mpv"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        // An extracted AppImage (AppDir) staged by desktop.yml; AppRun sets up the bundled .so
        // closure and execs mpv, so it runs without a system mpv or runtime FUSE.
        "mpv-linux-x64/AppRun"
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        "mpv-linux-arm64/AppRun"
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

/// A fresh, process-unique IPC endpoint path for mpv's `--input-ipc-server`. On Unix this is a Unix
/// domain socket inside a mode-0700 temporary directory; on Windows it is a named pipe path
/// (`\\.\pipe\...`), which mpv expects there. A monotonic counter keeps Windows pipe names unique;
/// the Unix directory itself is already random and unique.
fn fresh_ipc_endpoint() -> Result<(PathBuf, Option<tempfile::TempDir>), String> {
    #[cfg(target_os = "windows")]
    {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let seq = SEQ.fetch_add(1, Ordering::Relaxed);
        let unique = format!("stremiox-mpv-{}-{}", std::process::id(), seq);
        // Named pipes are not filesystem paths; build the pipe name directly.
        Ok((PathBuf::from(format!(r"\\.\pipe\{unique}")), None))
    }
    #[cfg(not(target_os = "windows"))]
    {
        let directory = tempfile::Builder::new()
            .prefix("stremiox-mpv-")
            .permissions(std::fs::Permissions::from_mode(0o700))
            .tempdir()
            .map_err(|error| format!("create private mpv IPC directory: {error}"))?;
        let mode = directory
            .path()
            .metadata()
            .map_err(|error| format!("verify mpv IPC directory: {error}"))?
            .permissions()
            .mode()
            & 0o077;
        if mode != 0 {
            return Err("mpv IPC directory is accessible outside the current user".to_owned());
        }
        // Keep the socket basename short: Unix-domain socket paths have a small platform limit, and
        // the OS temp directory can already be long (notably under macOS /var/folders).
        let socket = directory.path().join("mpv.sock");
        Ok((socket, Some(directory)))
    }
}

/// True only for the embedded server's torrent-file route:
/// `http://127.0.0.1:11470/<40-hex-infohash>/<decimal-index>`.
///
/// Reject every other local route, query, and authority form because the bundled server also has
/// redirecting `/yt`, `/proxy`, and root handlers. Passing one of those to native mpv would turn a
/// loopback-only gate back into a remote fetch.
fn is_loopback_torrent_url(url: &str) -> bool {
    let Ok(uri) = url.parse::<http::Uri>() else {
        return false;
    };
    if uri.scheme_str() != Some("http")
        || uri.authority().map(|authority| authority.as_str()) != Some(SERVER_AUTHORITY)
        || uri.query().is_some()
    {
        return false;
    }
    // Require the numeric host exactly. `localhost` is intentionally rejected because hosts-file
    // resolution is mutable and therefore cannot prove the request remains on loopback.
    let mut components = uri.path().split('/');
    let (Some(""), Some(info_hash), Some(file_index), None) = (
        components.next(),
        components.next(),
        components.next(),
        components.next(),
    ) else {
        return false;
    };
    info_hash.len() == 40
        && info_hash.bytes().all(|byte| byte.is_ascii_hexdigit())
        && !file_index.is_empty()
        && file_index.bytes().all(|byte| byte.is_ascii_digit())
        && file_index.parse::<u32>().is_ok()
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
    run_lifecycle(&PLAYER_LIFECYCLE, || {
        play_locked(resource_dir, url, wid, server_listening)
    })
}

fn play_locked(
    resource_dir: &Path,
    url: &str,
    wid: Option<isize>,
    server_listening: bool,
) -> Result<(), String> {
    // A new play request always owns the single-player slot, even when policy rejects the new URL.
    // This prevents a prior native child continuing behind a webview fallback.
    stop_locked();

    // Validate the URL is one we will play: http(s) only. Reject anything else (file://, data:, etc.)
    // so a crafted stream URL can't point mpv at the local filesystem.
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("refusing to play a non-http(s) URL".to_owned());
    }

    play_native(resource_dir, url, wid, server_listening)
}

#[cfg(target_os = "windows")]
fn play_native(
    _resource_dir: &Path,
    _url: &str,
    _wid: Option<isize>,
    _server_listening: bool,
) -> Result<(), String> {
    Err("secure native playback on Windows requires bounded named-pipe IPC support".to_owned())
}

#[cfg(not(target_os = "windows"))]
fn play_native(
    resource_dir: &Path,
    url: &str,
    wid: Option<isize>,
    server_listening: bool,
) -> Result<(), String> {
    let loopback = is_loopback_torrent_url(url);
    if !loopback {
        return Err(
            "secure native playback for remote URLs requires an attested bundled mpv runtime"
                .to_owned(),
        );
    }

    // TORRENT GATE (defensive backstop). The primary gate is the TS resolveUrl pipeline, which only
    // yields a loopback URL once isListening() is true. Re-check here so a loopback URL can never be
    // played while the embedded server is down.
    if !server_listening {
        return Err(
            "the embedded streaming server is not listening yet; torrent stream not ready"
                .to_owned(),
        );
    }

    let mpv_bin = resolve_mpv_binary(resource_dir).ok_or_else(|| {
        format!(
            "mpv runtime missing ({}). Drop the mpv binary into resources/ (see fetch-server-deps.sh) or install mpv on PATH.",
            mpv_binary_name()
        )
    })?;

    let (ipc_path, ipc_directory) = fresh_ipc_endpoint().inspect_err(|reason| {
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
    })?;
    let supervisor = spawn_mpv(&mpv_bin, &ipc_path, wid).map_err(|e| {
        let reason = format!("failed to launch mpv: {e}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        reason
    })?;

    let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
    let supervisor = Arc::new(Mutex::new(Some(supervisor)));
    let replaced = replace_player_recovering_poison(
        &PLAYER,
        Player {
            supervisor: Arc::clone(&supervisor),
            generation,
            ipc_path: ipc_path.clone(),
            _ipc_directory: ipc_directory,
        },
    );
    if let Some(player) = replaced {
        // Concurrent play commands should be serialized by the frontend, but fail closed if a
        // second child was nevertheless still parked. Dropping Child alone does not terminate it.
        terminate_player(player);
    }

    let start_result = supervisor
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .as_mut()
        .expect("player supervisor was parked before start")
        .start();
    if let Err(error) = start_result {
        stop_locked();
        let reason = format!("failed to start supervised mpv: {error}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        return Err(reason);
    }

    // Wait for the IPC socket, then loadfile. If the socket never appears, mpv almost certainly died
    // on startup (bad flag, missing GPU); surface that as Failed and clean up.
    if let Err(e) = wait_for_ipc(&ipc_path) {
        stop_locked();
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
        stop_locked();
        let reason = format!("failed to load the stream in mpv: {e}");
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        return Err(reason);
    }

    set_state(PlayerState::Playing);
    if let Err(reason) = spawn_player_monitor(generation, supervisor) {
        stop_locked();
        set_state(PlayerState::Failed {
            reason: reason.clone(),
        });
        return Err(reason);
    }
    Ok(())
}

/// Spawn the parked mpv supervisor with the DV-aware, loopback-friendly target arguments. The
/// target itself does not start until `play_native` stores the supervisor and sends its GO byte.
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
/// - trust-policy flags disable late config/script/watch-later overrides, require peer verification
///   at mpv and FFmpeg levels, and propagate the FFmpeg option to adaptive child requests.
/// - `--wid=<handle>`             : embed into the host window surface when one was provided.
fn spawn_mpv(
    mpv_bin: &Path,
    ipc_path: &Path,
    wid: Option<isize>,
) -> std::io::Result<SupervisedChild> {
    let mut cmd = SupervisedChild::command(mpv_bin, &mpv_args(ipc_path, wid))?;
    cmd.stdout(Stdio::null()).stderr(Stdio::null());

    SupervisedChild::spawn(cmd)
}

fn mpv_args(ipc_path: &Path, wid: Option<isize>) -> Vec<String> {
    let mut args = vec![
        format!("--input-ipc-server={}", ipc_path.to_string_lossy()),
        "--vo=gpu-next".to_owned(),
        "--gpu-api=auto".to_owned(),
        "--hwdec=auto-safe".to_owned(),
        "--tone-mapping=bt.2390".to_owned(),
        "--force-window=immediate".to_owned(),
        "--keep-open=no".to_owned(),
        "--idle=once".to_owned(),
        "--no-terminal".to_owned(),
        "--really-quiet".to_owned(),
    ];
    args.extend(REQUIRED_MPV_SECURITY_ARGS.map(str::to_owned));

    if let Some(handle) = wid {
        // mpv reads --wid as the native parent (X11 Window / HWND / NSView pointer). Embedding keeps
        // playback inside the app window; without it mpv opens its own borderless window, which is a
        // fine fallback on platforms where embedding is unreliable.
        args.push(format!("--wid={handle}"));
    }
    args
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

/// Send one app-owned command to the running player. Kept private so Tauri cannot expose arbitrary
/// mpv option/config/script mutation to the webview.
fn command(value: &Value) -> Result<Value, String> {
    let ipc_path = {
        let guard = PLAYER
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match guard.as_ref() {
            Some(p) => p.ipc_path.clone(),
            None => return Err("no player is running".to_owned()),
        }
    };
    send_ipc(&ipc_path, value)
}

/// Pause or resume the active player through a fixed command shape.
pub fn set_paused(paused: bool) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let _ = paused;
        Err("native player transport is disabled on Windows".to_owned())
    }
    #[cfg(not(target_os = "windows"))]
    {
        command(&json!({ "command": ["set_property", "pause", paused] })).map(|_| ())
    }
}

/// Seek relative to the current position. Reject non-finite and implausibly large offsets before
/// IPC so the public boundary cannot be repurposed as a generic command channel.
pub fn seek_relative(seconds: f64) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        let _ = seconds;
        Err("native player transport is disabled on Windows".to_owned())
    }
    #[cfg(not(target_os = "windows"))]
    {
        const MAX_RELATIVE_SEEK_SECONDS: f64 = 24.0 * 60.0 * 60.0;
        if !seconds.is_finite() || seconds.abs() > MAX_RELATIVE_SEEK_SECONDS {
            return Err("relative seek must be finite and within 24 hours".to_owned());
        }
        command(&json!({ "command": ["seek", seconds, "relative"] })).map(|_| ())
    }
}

/// Stop and reap the supervised mpv target, then reset state. Idempotent. Tries a graceful `quit`
/// over IPC first, then closes the supervisor ownership pipe, which force-kills and waits mpv.
pub fn stop() {
    run_lifecycle(&PLAYER_LIFECYCLE, stop_locked);
}

fn stop_locked() {
    // Capture the exact position before tearing mpv down, so quitting (or switching titles) records an
    // accurate resume point. Done while PLAYER still holds the running child, so the IPC read succeeds.
    #[cfg(not(target_os = "windows"))]
    report_position_now();

    let player = PLAYER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();

    if let Some(player) = player {
        terminate_player(player);
    }

    set_state(PlayerState::Idle {
        reason: "stopped".to_owned(),
    });
}

/// Park a new supervised child even after a prior panic poisoned the mutex. Silently skipping this
/// store would lose the only ownership-pipe writer and helper reap handle.
fn replace_player_recovering_poison(
    slot: &Mutex<Option<Player>>,
    player: Player,
) -> Option<Player> {
    slot.lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .replace(player)
}

/// Ask mpv to quit, then close the ownership pipe and wait until the helper has killed and reaped it.
fn terminate_player(player: Player) {
    #[cfg(not(target_os = "windows"))]
    let _ = send_ipc(&player.ipc_path, &json!({ "command": ["quit"] }));
    let supervisor = player
        .supervisor
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    if let Some(supervisor) = supervisor {
        supervisor.shutdown_and_wait();
    }
    // Best-effort: drop the stale Unix socket file (named pipes vanish with the process).
    #[cfg(not(target_os = "windows"))]
    {
        let _ = std::fs::remove_file(&player.ipc_path);
    }
}

/// Poll the parked supervisor so an mpv crash cannot leave `Playing` stale. The generation check
/// makes the exit notification ownership-specific: an old monitor can never clear or relabel a
/// newer play that has already replaced its slot.
fn spawn_player_monitor(
    generation: u64,
    supervisor: Arc<Mutex<Option<SupervisedChild>>>,
) -> Result<(), String> {
    std::thread::Builder::new()
        .name("vortx-mpv-monitor".to_owned())
        .spawn(move || loop {
            let exit = {
                let mut slot = supervisor
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                match slot.as_mut() {
                    Some(child) => match child.try_wait() {
                        Ok(Some(status)) => {
                            slot.take();
                            Some(format!("mpv supervisor exited ({status})"))
                        }
                        Ok(None) => None,
                        Err(error) => {
                            if let Some(child) = slot.take() {
                                child.shutdown_and_wait();
                            }
                            Some(format!("mpv supervisor wait failed: {error}"))
                        }
                    },
                    None => return,
                }
            };
            if let Some(reason) = exit {
                handle_player_exit(generation, &supervisor, reason);
                return;
            }
            std::thread::sleep(Duration::from_millis(100));
        })
        .map(|_| ())
        .map_err(|error| format!("failed to start mpv crash monitor: {error}"))
}

fn handle_player_exit(
    generation: u64,
    supervisor: &Arc<Mutex<Option<SupervisedChild>>>,
    reason: String,
) {
    run_lifecycle(&PLAYER_LIFECYCLE, || {
        let removed = {
            let mut slot = PLAYER
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if slot.as_ref().is_some_and(|player| {
                player.generation == generation && Arc::ptr_eq(&player.supervisor, supervisor)
            }) {
                slot.take()
            } else {
                None
            }
        };
        if removed.is_some() {
            set_state(PlayerState::Failed { reason });
        }
    });
}

fn run_lifecycle<T>(lock: &Mutex<()>, operation: impl FnOnce() -> T) -> T {
    let _guard = lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    operation()
}

// ---- IPC transport (platform-specific) ---------------------------------------------------------
//
// mpv's JSON IPC uses a unix domain socket on macOS/Linux and a named pipe on Windows. The std lib
// has no cross-platform abstraction for these, so each platform has a small connect helper; the
// request/response framing (one JSON line out, one line back) is shared.

/// Write one JSON command line and read one reply line over the IPC endpoint.
fn send_ipc(ipc_path: &Path, value: &Value) -> Result<Value, String> {
    let deadline = Instant::now() + IPC_IO_TIMEOUT;
    let mut stream = try_connect(ipc_path)?;
    configure_ipc_deadline_mode(&stream)?;
    let mut line = serde_json::to_string(value).map_err(|e| format!("encode command: {e}"))?;
    line.push('\n');
    write_ipc_request(&mut stream, line.as_bytes(), deadline)?;
    let reply = read_reply(&mut stream, deadline)?;
    match reply.get("error").and_then(Value::as_str) {
        Some("success") => Ok(reply),
        Some(error) => Err(format!("mpv IPC command failed: {error}")),
        None => Err("mpv IPC reply did not contain a result".to_owned()),
    }
}

/// Read newline-delimited JSON replies until we get one that is NOT an async event (mpv interleaves
/// `{"event":...}` notifications with command replies). Returns the first non-event JSON object.
fn read_reply(stream: &mut IpcStream, deadline: Instant) -> Result<Value, String> {
    configure_ipc_deadline_mode(stream)?;
    let mut pending = Vec::new();
    let mut received = 0usize;
    loop {
        while let Some(newline) = pending.iter().position(|byte| *byte == b'\n') {
            let mut remainder = pending.split_off(newline + 1);
            std::mem::swap(&mut pending, &mut remainder);
            remainder.pop();
            let parsed: Value = match serde_json::from_slice(&remainder) {
                Ok(value) => value,
                Err(_) => continue,
            };
            if parsed.get("event").is_none() {
                return Ok(parsed);
            }
        }

        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or_else(|| "mpv IPC response exceeded its wall deadline".to_owned())?;

        let mut chunk = [0u8; 1024];
        match stream.read(&mut chunk) {
            Ok(0) => return Err("mpv IPC closed before replying".to_owned()),
            Ok(read) => {
                received = received.saturating_add(read);
                if received > IPC_RESPONSE_LIMIT {
                    return Err("mpv IPC response exceeded its size limit".to_owned());
                }
                pending.extend_from_slice(&chunk[..read]);
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(remaining.min(Duration::from_millis(5)));
            }
            Err(error) if error.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(error) => return Err(format!("read IPC reply: {error}")),
        }
    }
}

#[cfg(not(target_os = "windows"))]
fn configure_ipc_deadline_mode(stream: &IpcStream) -> Result<(), String> {
    stream
        .set_nonblocking(true)
        .map_err(|error| format!("set IPC nonblocking mode: {error}"))
}

#[cfg(target_os = "windows")]
fn configure_ipc_deadline_mode(_stream: &IpcStream) -> Result<(), String> {
    Err("native player transport is disabled on Windows".to_owned())
}

fn write_ipc_request(
    stream: &mut IpcStream,
    request: &[u8],
    deadline: Instant,
) -> Result<(), String> {
    let mut written = 0usize;
    while written < request.len() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or_else(|| "mpv IPC request exceeded its wall deadline".to_owned())?;
        match stream.write(&request[written..]) {
            Ok(0) => return Err("mpv IPC closed while writing the command".to_owned()),
            Ok(count) => written += count,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(remaining.min(Duration::from_millis(5)));
            }
            Err(error) => return Err(format!("write IPC command: {error}")),
        }
    }
    stream
        .flush()
        .map_err(|error| format!("flush IPC command: {error}"))
}

/// A connected IPC stream: a UnixStream on Unix, a File over the named pipe on Windows. Both
/// implement Read + Write, which is all the framing code needs.
#[cfg(not(target_os = "windows"))]
type IpcStream = std::os::unix::net::UnixStream;
#[cfg(target_os = "windows")]
type IpcStream = std::fs::File;

/// Connect to mpv's IPC endpoint. `send_ipc` switches it to nonblocking mode and enforces one wall
/// deadline across request and response, so trickled reads cannot reset a per-syscall timer.
#[cfg(not(target_os = "windows"))]
fn try_connect(ipc_path: &Path) -> Result<IpcStream, String> {
    std::os::unix::net::UnixStream::connect(ipc_path)
        .map_err(|error| format!("connect mpv IPC socket: {error}"))
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
    use std::process::Command;
    use std::sync::mpsc;

    static TEST_GUARD: Mutex<()> = Mutex::new(());

    fn spawn_dummy_player(generation: u64) -> (Player, u32) {
        #[cfg(not(target_os = "windows"))]
        let child = Command::new("sleep")
            .arg("30")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn dummy player");
        #[cfg(target_os = "windows")]
        let child = Command::new("cmd")
            .args(["/C", "ping", "-n", "30", "127.0.0.1"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn dummy player");
        let pid = child.id();
        let ipc_directory = tempfile::tempdir().expect("dummy IPC directory");
        (
            Player {
                supervisor: Arc::new(Mutex::new(Some(SupervisedChild::unsupervised(child)))),
                generation,
                ipc_path: ipc_directory.path().join("mpv.sock"),
                _ipc_directory: Some(ipc_directory),
            },
            pid,
        )
    }

    fn pid_is_alive(pid: u32) -> bool {
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
                .map(|output| String::from_utf8_lossy(&output.stdout).contains(&pid.to_string()))
                .unwrap_or(false)
        }
    }

    #[test]
    fn status_defaults_to_idle_before_play() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stop();
        match status() {
            PlayerState::Idle { .. } => {}
            other => panic!("expected Idle before play, got {other:?}"),
        }
    }

    #[test]
    fn exact_loopback_torrent_urls_are_recognized() {
        assert!(is_loopback_torrent_url(
            "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0"
        ));
        assert!(is_loopback_torrent_url(
            "http://127.0.0.1:11470/ABCDEF0123456789ABCDEF0123456789ABCDEF01/4294967295"
        ));
        assert!(!is_loopback_torrent_url(
            "https://cdn.example.com/movie.mkv"
        ));
        assert!(!is_loopback_torrent_url("http://127.0.0.1:8080/other"));
        assert!(!is_loopback_torrent_url(
            "http://localhost:11470/0123456789abcdef0123456789abcdef01234567/0"
        ));
        assert!(!is_loopback_torrent_url(
            "http://evil.example/?next=http://127.0.0.1:11470/abc/1"
        ));
        assert!(!is_loopback_torrent_url(
            "http://127.0.0.1.evil.example:11470/abc/1"
        ));
        for rejected in [
            "https://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0",
            "http://127.0.0.1:11470/yt/video",
            "http://127.0.0.1:11470/proxy/0",
            "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/create",
            "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0?redirect=1",
            "http://user@127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0",
            "http://127.0.0.1:011470/0123456789abcdef0123456789abcdef01234567/0",
            "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/4294967296",
        ] {
            assert!(
                !is_loopback_torrent_url(rejected),
                "unexpectedly accepted: {rejected}"
            );
        }
    }

    #[test]
    fn play_rejects_non_http_urls() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
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
    #[cfg(not(target_os = "windows"))]
    fn remote_native_playback_requires_an_attested_bundle() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let err = play(
            &std::env::temp_dir(),
            "https://cdn.example.com/movie.mkv",
            None,
            true,
        )
        .unwrap_err();
        assert!(err.contains("attested bundled mpv runtime"), "got: {err}");
    }

    #[test]
    #[cfg(not(target_os = "windows"))]
    fn play_enforces_the_torrent_gate_for_loopback_urls() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir();
        // server NOT listening -> a loopback (torrent) URL must be refused before any spawn.
        let err = play(
            &dir,
            "http://127.0.0.1:11470/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/0",
            None,
            false,
        )
        .unwrap_err();
        assert!(
            err.contains("not listening"),
            "expected torrent-gate rejection, got: {err}"
        );
    }

    #[test]
    fn mpv_binary_name_matches_the_host_target() {
        #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
        let expected = "mpv-darwin-arm64.app/Contents/MacOS/mpv";
        #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
        let expected = "mpv-darwin-x64.app/Contents/MacOS/mpv";
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        let expected = "mpv-linux-x64/AppRun";
        #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
        let expected = "mpv-linux-arm64/AppRun";
        #[cfg(target_os = "windows")]
        let expected = "mpv-win-x64.exe";

        assert_eq!(mpv_binary_name(), expected);
    }

    #[test]
    fn fresh_ipc_path_is_unique_and_platform_shaped() {
        let (a, a_directory) = fresh_ipc_endpoint().expect("first private IPC path");
        let (b, b_directory) = fresh_ipc_endpoint().expect("second private IPC path");
        assert_ne!(a, b, "consecutive IPC paths must differ");
        #[cfg(target_os = "windows")]
        assert!(a.to_string_lossy().starts_with(r"\\.\pipe\"));
        #[cfg(not(target_os = "windows"))]
        {
            assert!(a.to_string_lossy().ends_with(".sock"));
            let directory = a.parent().expect("IPC directory");
            assert_eq!(
                std::fs::metadata(directory)
                    .expect("private IPC directory metadata")
                    .permissions()
                    .mode()
                    & 0o077,
                0
            );
        }
        drop(a_directory);
        drop(b_directory);
    }

    #[test]
    fn spawned_mpv_args_fail_closed_on_media_tls() {
        let args = mpv_args(Path::new("/tmp/vortx-test.sock"), Some(42));
        let expected_security = [
            "--no-config",
            "--load-scripts=no",
            "--resume-playback=no",
            "--tls-verify=yes",
            "--stream-lavf-o=tls_verify=1,reconnect=1,reconnect_streamed=1,reconnect_delay_max=7",
            "--demuxer-lavf-o=tls_verify=1",
            "--demuxer-lavf-propagate-opts=yes",
        ];
        let security_start = args
            .iter()
            .position(|argument| argument == expected_security[0])
            .expect("security policy starts after ordinary args");
        assert_eq!(
            args[security_start..security_start + expected_security.len()]
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            expected_security
        );
        assert_eq!(
            args.iter()
                .filter(|argument| argument.starts_with("--tls-verify="))
                .count(),
            1
        );
        assert!(args.iter().any(|argument| argument == "--idle=once"));
        assert!(args.iter().any(|argument| argument == "--wid=42"));
    }

    #[test]
    #[cfg(not(target_os = "windows"))]
    fn ipc_reply_skips_events_within_one_bounded_exchange() {
        let (mut reader, mut writer) =
            std::os::unix::net::UnixStream::pair().expect("IPC socket pair");
        writer
            .write_all(b"{\"event\":\"property-change\"}\n{\"error\":\"success\",\"data\":42}\n")
            .expect("write IPC replies");
        drop(writer);
        let reply = read_reply(&mut reader, Instant::now() + Duration::from_secs(1))
            .expect("bounded IPC reply");
        assert_eq!(reply.get("data").and_then(Value::as_i64), Some(42));
    }

    #[test]
    #[cfg(not(target_os = "windows"))]
    fn ipc_reply_rejects_an_oversized_peer_response() {
        let (mut reader, mut writer) =
            std::os::unix::net::UnixStream::pair().expect("IPC socket pair");
        let sender = std::thread::spawn(move || {
            let oversized = vec![b'x'; IPC_RESPONSE_LIMIT + 1];
            let _ = writer.write_all(&oversized);
        });
        let error = read_reply(&mut reader, Instant::now() + Duration::from_secs(2))
            .expect_err("oversized IPC must fail");
        drop(reader);
        sender.join().expect("oversized response writer");
        assert!(error.contains("size limit"), "got: {error}");
    }

    #[test]
    #[cfg(not(target_os = "windows"))]
    fn ipc_reply_trickle_cannot_reset_the_shared_wall_deadline() {
        let (mut reader, mut writer) =
            std::os::unix::net::UnixStream::pair().expect("IPC socket pair");
        let sender = std::thread::spawn(move || {
            for _ in 0..50 {
                if writer.write_all(b"x").is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        let error = read_reply(&mut reader, started + Duration::from_millis(120))
            .expect_err("trickled IPC must time out");
        let elapsed = started.elapsed();
        drop(reader);
        sender.join().expect("trickle writer");
        assert!(error.contains("timed out") || error.contains("wall deadline"));
        assert!(
            elapsed < Duration::from_millis(500),
            "trickle extended the wall deadline to {elapsed:?}"
        );
    }

    /// Typed transport with no running player returns an error rather than panicking.
    #[test]
    #[cfg(not(target_os = "windows"))]
    fn typed_transport_without_a_running_player_errors() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // Ensure no player is parked from another test.
        stop();
        let err = set_paused(true).unwrap_err();
        assert!(err.contains("no player is running"), "got: {err}");
    }

    #[test]
    #[cfg(target_os = "windows")]
    fn windows_native_playback_stays_disabled_for_every_http_source() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for url in [
            "http://127.0.0.1:11470/0123456789abcdef0123456789abcdef01234567/0",
            "https://cdn.example.com/movie.mkv",
        ] {
            let error = play(&std::env::temp_dir(), url, None, true).unwrap_err();
            assert!(error.contains("bounded named-pipe IPC"), "got: {error}");
        }
        assert!(set_paused(true)
            .unwrap_err()
            .contains("disabled on Windows"));
    }

    #[test]
    fn relative_seek_rejects_non_finite_and_unbounded_offsets() {
        assert!(seek_relative(f64::NAN).is_err());
        assert!(seek_relative(f64::INFINITY).is_err());
        assert!(seek_relative(24.0 * 60.0 * 60.0 + 1.0).is_err());
    }

    #[test]
    fn stop_during_spawn_waits_then_removes_the_parked_child() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stop();
        let (spawn_entered_tx, spawn_entered_rx) = mpsc::channel();
        let (release_spawn_tx, release_spawn_rx) = mpsc::channel();
        let (pid_tx, pid_rx) = mpsc::channel();
        let play_thread = std::thread::spawn(move || {
            run_lifecycle(&PLAYER_LIFECYCLE, || {
                spawn_entered_tx.send(()).expect("signal spawn entry");
                release_spawn_rx.recv().expect("release simulated spawn");
                let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
                let (player, pid) = spawn_dummy_player(generation);
                replace_player_recovering_poison(&PLAYER, player);
                set_state(PlayerState::Playing);
                pid_tx.send(pid).expect("publish dummy player pid");
            });
        });
        spawn_entered_rx.recv().expect("simulated spawn entered");

        let (stop_done_tx, stop_done_rx) = mpsc::channel();
        let stop_thread = std::thread::spawn(move || {
            stop();
            stop_done_tx.send(()).expect("signal stop completion");
        });
        assert!(
            stop_done_rx
                .recv_timeout(Duration::from_millis(100))
                .is_err(),
            "stop must not return while a play transition can still park a child"
        );

        release_spawn_tx.send(()).expect("release simulated spawn");
        let pid = pid_rx.recv().expect("dummy player pid");
        play_thread.join().expect("play transition thread");
        stop_done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("bounded serialized stop");
        stop_thread.join().expect("stop thread");
        assert!(
            PLAYER
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_none(),
            "stop must remove the child parked by the in-flight play"
        );
        assert!(!pid_is_alive(pid), "serialized stop must reap the child");
    }

    #[test]
    fn concurrent_play_transitions_never_overlap_or_kill_the_winner() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stop();
        let (first_entered_tx, first_entered_rx) = mpsc::channel();
        let (release_first_tx, release_first_rx) = mpsc::channel();
        let (second_entered_tx, second_entered_rx) = mpsc::channel();
        let (first_pid_tx, first_pid_rx) = mpsc::channel();
        let (second_pid_tx, second_pid_rx) = mpsc::channel();

        let first = std::thread::spawn(move || {
            run_lifecycle(&PLAYER_LIFECYCLE, || {
                first_entered_tx.send(()).expect("first play entered");
                release_first_rx.recv().expect("release first play");
                let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
                let (player, pid) = spawn_dummy_player(generation);
                replace_player_recovering_poison(&PLAYER, player);
                set_state(PlayerState::Playing);
                first_pid_tx.send(pid).expect("first player pid");
            });
        });
        first_entered_rx
            .recv()
            .expect("first play transition entered");

        let second = std::thread::spawn(move || {
            run_lifecycle(&PLAYER_LIFECYCLE, || {
                second_entered_tx.send(()).expect("second play entered");
                stop_locked();
                let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
                let (player, pid) = spawn_dummy_player(generation);
                replace_player_recovering_poison(&PLAYER, player);
                set_state(PlayerState::Playing);
                second_pid_tx.send(pid).expect("second player pid");
            });
        });
        assert!(
            second_entered_rx
                .recv_timeout(Duration::from_millis(100))
                .is_err(),
            "a second play must wait for the first complete transition"
        );

        release_first_tx.send(()).expect("release first play");
        let first_pid = first_pid_rx.recv().expect("first player pid");
        first.join().expect("first play thread");
        second_entered_rx
            .recv_timeout(Duration::from_secs(2))
            .expect("second play eventually enters");
        let second_pid = second_pid_rx.recv().expect("second player pid");
        second.join().expect("second play thread");

        assert!(
            !pid_is_alive(first_pid),
            "the serialized replacement must reap its predecessor"
        );
        assert!(
            pid_is_alive(second_pid),
            "an older play cannot run late cleanup against the newer winner"
        );
        stop();
        assert!(
            !pid_is_alive(second_pid),
            "test cleanup must reap the winning child"
        );
    }

    #[test]
    fn lifecycle_lock_recovers_after_poison() {
        let lock = Mutex::new(());
        let _ = std::panic::catch_unwind(|| {
            run_lifecycle(&lock, || panic!("deliberately poison lifecycle lock"));
        });
        let completed = run_lifecycle(&lock, || true);
        assert!(completed, "poison recovery must keep teardown reachable");
    }

    #[test]
    fn crashed_player_monitor_clears_playing_and_reaps_its_generation() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stop();
        #[cfg(not(target_os = "windows"))]
        let child = Command::new("true").spawn().expect("spawn exiting player");
        #[cfg(target_os = "windows")]
        let child = Command::new("cmd")
            .args(["/C", "exit", "0"])
            .spawn()
            .expect("spawn exiting player");
        let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
        let supervisor = Arc::new(Mutex::new(Some(SupervisedChild::unsupervised(child))));
        let ipc_directory = tempfile::tempdir().expect("monitor IPC directory");
        replace_player_recovering_poison(
            &PLAYER,
            Player {
                supervisor: Arc::clone(&supervisor),
                generation,
                ipc_path: ipc_directory.path().join("mpv.sock"),
                _ipc_directory: Some(ipc_directory),
            },
        );
        set_state(PlayerState::Playing);
        spawn_player_monitor(generation, supervisor).expect("start crash monitor");

        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if PLAYER
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .is_none()
                && matches!(status(), PlayerState::Failed { .. })
            {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("crashed player monitor left a stale Playing generation");
    }

    #[test]
    fn stale_monitor_exit_cannot_clear_a_newer_player_generation() {
        let _guard = TEST_GUARD
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        stop();
        let stale_supervisor = Arc::new(Mutex::new(None));
        let generation = NEXT_PLAYER_GENERATION.fetch_add(1, Ordering::SeqCst);
        let (winner, winner_pid) = spawn_dummy_player(generation);
        replace_player_recovering_poison(&PLAYER, winner);
        set_state(PlayerState::Playing);

        handle_player_exit(
            generation.saturating_sub(1),
            &stale_supervisor,
            "stale monitor exit".to_owned(),
        );

        let parked_generation = PLAYER
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .as_ref()
            .map(|player| player.generation);
        assert_eq!(parked_generation, Some(generation));
        assert!(matches!(status(), PlayerState::Playing));
        assert!(pid_is_alive(winner_pid));
        stop();
    }

    #[test]
    fn poisoned_player_slot_still_retains_the_child_for_reaping() {
        let slot: Mutex<Option<Player>> = Mutex::new(None);
        let _ = std::panic::catch_unwind(|| {
            let _guard = slot.lock().expect("unpoisoned test slot");
            panic!("deliberately poison the player slot");
        });
        assert!(slot.is_poisoned(), "test must exercise the poisoned path");

        let (player, _) = spawn_dummy_player(1);
        assert!(
            replace_player_recovering_poison(&slot, player).is_none(),
            "empty poisoned slot should not replace another child"
        );

        let parked = slot
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take()
            .expect("child remains reachable after poisoned-slot recovery");
        terminate_player(parked);
    }
}
