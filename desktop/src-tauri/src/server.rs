//! Embedded streaming server for the desktop app.
//!
//! Runs Stremio's `server.cjs` (the torrent engine + `/proxy` + HLS) in a CHILD PROCESS bound to
//! `http://127.0.0.1:11470`, so TORRENT streams play on desktop (the app was direct/debrid only).
//!
//! This is the Tauri/Rust twin of the macOS app's `app/SourcesShared/MacNodeServer.swift`: that app
//! is unsandboxed and spawns the ordinary standalone `node` with Foundation's `Process`; here we
//! bundle the same standalone `node` (fetched into `resources/` by `scripts/fetch-server-deps.sh`)
//! and launch it through a same-binary Rust supervisor. The env handling (HOME / APP_PATH / NO_CORS /
//! CASTING_DISABLED / UV_THREADPOOL_SIZE / ffmpeg discovery incl. Homebrew's Apple-silicon prefix)
//! and the loopback-bind preload are ported directly from MacNodeServer.
//!
//! A monitor thread waits on the child and restarts it (bounded, backed off) if it dies unexpectedly,
//! so a single crash doesn't permanently kill torrent playback. The child is force-killed on app
//! exit. The frontend learns the base URL + liveness through the `server_status` / `server_base_url`
//! Tauri commands (see lib.rs). Readiness is not inferred from port ownership: every node child gets
//! a fresh private owner key and must answer a bounded HMAC challenge through the preload before the
//! frontend may rely on it. The frontend then primes a torrent by POSTing
//! `<base>/<infohash>/create` itself (mirroring the Apple `prepareTorrent`) and plays
//! `<base>/<infohash>/<fileIdx>`.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::process::Child;
#[cfg(any(unix, test))]
use std::process::Command;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use hmac::{Hmac, Mac};
use once_cell::sync::Lazy;
use serde::Serialize;
use sha2::Sha256;

use crate::child_supervisor::SupervisedChild;

/// How often the monitor polls the live child for exit. Short enough that a crash is noticed and
/// restarted promptly, long enough to stay idle-cheap. The monitor holds no lock between polls, so
/// `stop()` can always reach the child to kill it.
const MONITOR_POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Loopback host + port the embedded server binds. Matches the Apple app's `StremioServer.embedded`
/// and the port server.js listens on by default.
const HOST: &str = "127.0.0.1";
const PORT: u16 = 11470;

/// Owner-authenticated readiness protocol. Each node child receives a fresh secret through its
/// inherited environment; the preload removes the variable before loading server.cjs and retains
/// the key only in its closure. Rust sends a fresh random challenge and accepts readiness only when
/// the listener returns the matching HMAC. A process that merely occupies the port cannot pass.
const HEALTH_TOKEN_ENV: &str = "VORTX_DESKTOP_HEALTH_TOKEN";
const HEALTH_PATH: &str = "/__vortx_owner_health";
const HEALTH_CHALLENGE_HEADER: &str = "X-VortX-Health-Challenge";
const HEALTH_SECRET_BYTES: usize = 32;
const HEALTH_PROOF_HEX_BYTES: usize = 64;
const HEALTH_RESPONSE_LIMIT: usize = 1024;
const HEALTH_IO_TIMEOUT: Duration = Duration::from_millis(400);
type HealthToken = [u8; HEALTH_SECRET_BYTES];
type HealthMac = Hmac<Sha256>;

/// Restart policy: give up after this many crashes inside the window, so a server.js that can't boot
/// (missing dep, port held) doesn't spin forever. A clean run resets the counter.
const MAX_RESTARTS: u32 = 5;
const RESTART_WINDOW: Duration = Duration::from_secs(60);

/// Observable server state, surfaced to the frontend via `server_status`. An enum so illegal states
/// (e.g. "running" with no child) are unrepresentable.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ServerState {
    /// Never asked to start (e.g. resources missing). `reason` explains why, for the empty-state UI.
    Disabled { reason: String },
    /// Child spawned; may still be booting (the frontend waits for owner-authenticated readiness).
    Running,
    /// Child exited and we stopped restarting it. `reason` carries the last exit detail.
    Failed { reason: String },
}

struct Manager {
    /// The running supervisor, kept so we can poll it or close its ownership pipe. `None` once
    /// stopped.
    ///
    /// Shared with the monitor thread via `Arc<Mutex<…>>` so the child is reachable from BOTH the
    /// monitor (which polls it for exit) and `stop()` (which kills it). The monitor never holds this
    /// lock across a blocking wait; it polls with `try_wait()`, so `stop()` can always lock and
    /// tear down the live supervisor. This keeps the ownership pipe reachable from explicit stop
    /// while the helper independently covers app crash and SIGKILL.
    child: Arc<Mutex<Option<SupervisedChild>>>,
    /// Set by `stop()` to tell the monitor an exit is an intentional shutdown, NOT a crash to restart.
    /// Shared with the monitor; the `Manager` itself is dropped on stop, so the monitor's `Arc` clone
    /// keeps the flag alive.
    shutdown: Arc<AtomicBool>,
    /// Absolute paths resolved at startup (node binary + server.js + writable home).
    node_bin: PathBuf,
    server_js: PathBuf,
    home: PathBuf,
    /// Per-child owner key used only for the bounded readiness challenge. Rotated on every restart.
    health_token: HealthToken,
    /// Crash bookkeeping for the bounded-restart policy.
    restarts: u32,
    window_start: Instant,
}

static MANAGER: Lazy<Mutex<Option<Manager>>> = Lazy::new(Default::default);
static STATE: Lazy<RwLock<ServerState>> = Lazy::new(|| {
    RwLock::new(ServerState::Disabled {
        reason: "not started".to_owned(),
    })
});

fn set_state(state: ServerState) {
    if let Ok(mut guard) = STATE.write() {
        *guard = state;
    }
}

/// The active server base URL (`http://127.0.0.1:11470`). Always loopback on desktop.
pub fn base_url() -> String {
    format!("http://{HOST}:{PORT}")
}

/// Current server state, cloned for the Tauri command layer.
pub fn status() -> ServerState {
    STATE
        .read()
        .ok()
        .map(|g| g.clone())
        .unwrap_or(ServerState::Failed {
            reason: "status lock poisoned".to_owned(),
        })
}

/// The platform-tagged node binary name staged in `resources/` by `fetch-server-deps.sh`. server.js
/// is the same file everywhere; only the runtime differs per OS/arch. Keep this in lockstep with the
/// fetch script's `NODE_BIN_NAME`.
fn node_binary_name() -> &'static str {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "node-darwin-arm64"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "node-darwin-x64"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "node-linux-x64"
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        "node-linux-arm64"
    }
    #[cfg(target_os = "windows")]
    {
        "node-win-x64.exe"
    }
}

/// Locate an ffmpeg/ffprobe pair the server can use for HLS transcoding (and, on macOS,
/// VideoToolbox hw-accel). server.js's built-in search misses Homebrew's Apple-silicon prefix, so we
/// probe the common locations and hand the pair to node via FFMPEG_BIN / FFPROBE_BIN, the first
/// entries server.js honours. Direct port of MacNodeServer.ffmpegBinaries() (plus Linux/Windows
/// fallbacks); returns None when no usable pair is found (transcoding then no-ops, playback of an
/// already-web-ready file still works).
fn ffmpeg_binaries() -> Option<(PathBuf, PathBuf)> {
    #[cfg(target_os = "windows")]
    let (prefixes, ffmpeg_name, ffprobe_name): (&[&str], &str, &str) = (
        &["C:\\ffmpeg\\bin", "C:\\Program Files\\ffmpeg\\bin"],
        "ffmpeg.exe",
        "ffprobe.exe",
    );
    #[cfg(not(target_os = "windows"))]
    let (prefixes, ffmpeg_name, ffprobe_name): (&[&str], &str, &str) = (
        &[
            "/opt/homebrew/bin", // Homebrew, Apple silicon (server.js misses this)
            "/usr/local/bin",    // Homebrew Intel / manual installs
            "/usr/bin",          // system (typical Linux)
            "/bin",
        ],
        "ffmpeg",
        "ffprobe",
    );

    for prefix in prefixes {
        let ff = Path::new(prefix).join(ffmpeg_name);
        let fp = Path::new(prefix).join(ffprobe_name);
        if ff.is_file() && fp.is_file() {
            return Some((ff, fp));
        }
    }
    None
}

/// The preload JS injected with `node -r`. It (a) tees uncaught errors to a log file, (b) installs
/// the private HMAC health route, and (c) pins every host-less `server.listen(port)` to loopback
/// (127.0.0.1). Parent death is enforced outside JavaScript by the same-binary Rust supervisor:
/// node is its direct child, and ownership-pipe EOF makes the supervisor kill and wait node on
/// macOS, Linux, and Windows. server.js listens with no host, which Node treats as 0.0.0.0 (every
/// interface), so we monkeypatch `net.Server.prototype.listen` exactly like MacNodeServer.
fn write_preload(home: &Path) -> std::io::Result<PathBuf> {
    let preload_path = home.join("stremiox-preload.js");
    let log_path = home.join("stremio-server.log");
    let log_js = json_string(&log_path.to_string_lossy());
    let host_js = json_string(HOST);
    let health_env_js = json_string(HEALTH_TOKEN_ENV);
    let health_path_js = json_string(HEALTH_PATH);
    let health_header_js = json_string(&HEALTH_CHALLENGE_HEADER.to_ascii_lowercase());
    let preload = format!(
        r#"const fs=require('fs'),L={log},HENV={health_env},HPATH={health_path},HHEADER={health_header};
const TOKEN=process.env[HENV]||'';
delete process.env[HENV];
const w=(t,a)=>{{try{{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\n')}}catch(e){{}}}};
process.on('uncaughtException',function(e){{w('[uncaught]',[e&&e.stack||e])}});
process.on('unhandledRejection',function(e){{w('[rej]',[e&&e.stack||e])}});
try{{
  const http=require('http'),crypto=require('crypto'),origEmit=http.Server.prototype.emit;
  const key=/^[0-9a-f]{{64}}$/.test(TOKEN)?Buffer.from(TOKEN,'hex'):null;
  http.Server.prototype.emit=function(event,req,res){{
    if(event==='request' && req && req.url===HPATH){{
      const challenge=req.headers[HHEADER];
      if(req.method!=='GET' || !key || typeof challenge!=='string' || !/^[0-9a-f]{{64}}$/.test(challenge)){{
        res.writeHead(404,{{'Cache-Control':'no-store','Content-Length':0,'Connection':'close'}});
        res.end();
        return true;
      }}
      const proof=crypto.createHmac('sha256',key).update(challenge,'ascii').digest('hex');
      res.writeHead(200,{{'Content-Type':'text/plain','Cache-Control':'no-store','Content-Length':proof.length,'Connection':'close'}});
      res.end(proof);
      return true;
    }}
    return origEmit.apply(this,arguments);
  }};
  w('[health]',['owner challenge active']);
}}catch(e){{w('[health-err]',[e&&e.stack||e]);}}
try{{
  const net=require('net'),HOST={host},orig=net.Server.prototype.listen;
  net.Server.prototype.listen=function(){{
    const a=Array.prototype.slice.call(arguments);
    if(typeof a[0]==='number' && (a.length===1 || typeof a[1]==='function')){{
      const cb=a[1]; a[1]=HOST; if(cb)a[2]=cb;
      w('[bind]',['listen',a[0],'->',HOST]);
    }}
    return orig.apply(this,a);
  }};
  w('[boot]',['desktop preload active; bind='+HOST]);
}}catch(e){{w('[bind-err]',[e&&e.stack||e]);}}
"#,
        log = log_js,
        host = host_js,
        health_env = health_env_js,
        health_path = health_path_js,
        health_header = health_header_js,
    );
    std::fs::write(&preload_path, preload)?;
    Ok(preload_path)
}

/// JSON-encode a string for safe embedding in the preload JS source (handles Windows backslashes,
/// quotes, etc.). Always produces a quoted literal.
fn json_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_owned())
}

/// Generate a fresh 256-bit owner key from the operating system CSPRNG. A failure is fatal for this
/// child launch: starting without an authentication key would regress readiness to port ownership.
fn fresh_health_token() -> std::io::Result<HealthToken> {
    let mut token = [0u8; HEALTH_SECRET_BYTES];
    getrandom::fill(&mut token).map_err(|error| {
        std::io::Error::other(format!("generate embedded-server health token: {error}"))
    })?;
    Ok(token)
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[usize::from(byte >> 4)] as char);
        encoded.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    encoded
}

/// Spawn an unstarted same-binary supervisor configured for `node -r preload server.js`. Each
/// invocation creates a new owner key and returns it with the parked helper. The caller must store
/// the helper in manager-owned state before sending GO, so owner death before parking cannot launch
/// node and owner death afterwards makes the helper kill and wait node on every supported OS.
fn spawn_child(
    node_bin: &Path,
    server_js: &Path,
    home: &Path,
) -> std::io::Result<(SupervisedChild, HealthToken)> {
    let health_token = fresh_health_token()?;
    let server_data = home.join("stremio-server");
    std::fs::create_dir_all(&server_data)?;
    let preload = write_preload(home)?;

    // Tee the node process's own stdout/stderr into the same log the preload appends to, so a dead
    // server can explain itself. Append (don't truncate) so a prior boot's tail survives a restart.
    let log_path = home.join("stremio-server.log");
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)?;
    let log_err = log.try_clone()?;

    let target_args = vec![
        "-r".to_owned(),
        preload.to_string_lossy().into_owned(),
        server_js.to_string_lossy().into_owned(),
    ];
    let health_token_hex = hex_encode(&health_token);
    let mut cmd = SupervisedChild::command(node_bin, &target_args)?;
    cmd.current_dir(home)
        .env("HOME", home) // server reads HOME for its app-data path
        .env("APP_PATH", &server_data) // torrent cache + settings
        .env("NO_CORS", "1")
        .env("CASTING_DISABLED", "1") // no cast UI on desktop; skip the SSDP multicast loop
        .env("UV_THREADPOOL_SIZE", "16") // more libuv workers for tracker DNS + disk/crypto
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));

    if let Some((ffmpeg, ffprobe)) = ffmpeg_binaries() {
        cmd.env("FFMPEG_BIN", &ffmpeg).env("FFPROBE_BIN", &ffprobe);
    }

    // The owner key crosses the private control pipe only after the helper is parked. It is never
    // placed in the helper environment; node receives it at spawn and the preload immediately
    // deletes process.env[...] before server.cjs loads.
    SupervisedChild::spawn_with_private_env(cmd, &[(HEALTH_TOKEN_ENV, health_token_hex.as_str())])
        .map(|child| (child, health_token))
}

/// Before the first spawn, reclaim the port if a legacy STALE copy of OUR OWN node server is still
/// holding it. New supervised launches cannot orphan node when Tauri disappears on any supported
/// OS; this Unix-only cleanup remains for processes left by older builds. We match "ours" narrowly:
/// a process whose argv references the `stremiox-preload.js` we inject. An unrelated listener is
/// left alone. Best-effort: a missing/failing lsof/ps/kill simply skips legacy cleanup.
#[cfg(unix)]
fn reclaim_stale_port() {
    for pid in port_listeners(PORT) {
        if !is_our_node_server(&pid) {
            continue;
        }
        eprintln!("stremiox: reclaiming port {PORT} from a stale node server (pid {pid})");
        let _ = Command::new("kill").arg(&pid).status(); // SIGTERM; ask it to exit cleanly
        let deadline = Instant::now() + Duration::from_secs(2);
        while pid_alive(&pid) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        if pid_alive(&pid) {
            let _ = Command::new("kill").args(["-9", &pid]).status(); // SIGKILL; guarantee release
        }
    }
}

#[cfg(not(unix))]
fn reclaim_stale_port() {}

/// PIDs holding a LISTEN socket on `port` (via `lsof -t`); empty when the port is free or `lsof` is
/// unavailable. Kept as strings since we only ever feed them back to `ps`/`kill`.
#[cfg(unix)]
fn port_listeners(port: u16) -> Vec<String> {
    run_tool(
        "lsof",
        &["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-t"],
    )
    .map(|out| {
        out.lines()
            .map(|l| l.trim().to_owned())
            .filter(|l| !l.is_empty())
            .collect()
    })
    .unwrap_or_default()
}

/// True if `pid`'s argv references our injected `stremiox-preload.js`, the marker identifying one
/// of our embedded node servers (read via `ps -o command=`).
#[cfg(unix)]
fn is_our_node_server(pid: &str) -> bool {
    run_tool("ps", &["-o", "command=", "-p", pid])
        .map(|cmd| cmd.contains("stremiox-preload.js"))
        .unwrap_or(false)
}

/// `kill -0` probes for existence without delivering a signal: success ⇒ the process is alive.
#[cfg(unix)]
fn pid_alive(pid: &str) -> bool {
    Command::new("kill")
        .args(["-0", pid])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run a short helper tool and capture its stdout (None if it can't be launched). Used only for the
/// tiny, bounded `lsof`/`ps` probes above.
#[cfg(unix)]
fn run_tool(bin: &str, args: &[&str]) -> Option<String> {
    Command::new(bin)
        .args(args)
        .stderr(Stdio::null())
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
}

/// Start the embedded server once. Idempotent: a second call while running is a no-op. `resource_dir`
/// is the bundled resources directory (node binary + server.js live directly under it); `cache_dir`
/// is a writable per-user dir the server uses as HOME (its torrent cache + settings). Called from the
/// Tauri `.setup()` in lib.rs.
pub fn start(resource_dir: &Path, cache_dir: &Path) {
    let mut guard = MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if guard.is_some() {
        return; // already started
    }

    let node_bin = resource_dir.join(node_binary_name());
    // server.cjs (not .js): the bundle is CommonJS, but the desktop project's package.json declares
    // "type":"module", which would make Node treat a bare .js as ESM ("require is not defined") when
    // run from the source tree. The .cjs extension forces CommonJS. (See fetch-server-deps.sh.)
    let server_js = resource_dir.join("server.cjs");
    if !node_bin.exists() {
        set_state(ServerState::Disabled {
            reason: format!(
                "node runtime missing ({}). Run scripts/fetch-server-deps.sh before building.",
                node_binary_name()
            ),
        });
        return;
    }
    if !server_js.exists() {
        set_state(ServerState::Disabled {
            reason: "server.cjs missing from resources. Run scripts/fetch-server-deps.sh."
                .to_owned(),
        });
        return;
    }

    let home = cache_dir.to_path_buf();
    if let Err(err) = std::fs::create_dir_all(&home) {
        set_state(ServerState::Disabled {
            reason: format!("cannot create server home dir: {err}"),
        });
        return;
    }

    // Clear a narrowly identified legacy orphan left by an older Unix build before supervised spawn.
    reclaim_stale_port();

    match spawn_child(&node_bin, &server_js, &home) {
        Ok((child, health_token)) => {
            let child = Arc::new(Mutex::new(Some(child)));
            let shutdown = Arc::new(AtomicBool::new(false));
            // Clones the monitor thread owns for the lifetime of the server, so it can poll the child
            // and observe a shutdown request even after the `Manager` is dropped by `stop()`.
            let monitor_child = Arc::clone(&child);
            let monitor_shutdown = Arc::clone(&shutdown);
            *guard = Some(Manager {
                child: Arc::clone(&child),
                shutdown: Arc::clone(&shutdown),
                node_bin,
                server_js,
                home,
                health_token,
                restarts: 0,
                window_start: Instant::now(),
            });
            let start_result = child
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .as_mut()
                .expect("server supervisor was parked before start")
                .start();
            if let Err(error) = start_result {
                shutdown.store(true, Ordering::SeqCst);
                let parked = child
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .take();
                *guard = None;
                drop(guard);
                if let Some(child) = parked {
                    kill_child(child);
                }
                set_state(ServerState::Failed {
                    reason: format!("failed to start node supervisor: {error}"),
                });
                return;
            }
            set_state(ServerState::Running);
            drop(guard);
            if let Err(reason) = spawn_monitor(monitor_child, monitor_shutdown) {
                stop();
                set_state(ServerState::Failed { reason });
            }
        }
        Err(err) => set_state(ServerState::Failed {
            reason: format!("failed to launch node: {err}"),
        }),
    }
}

/// Background thread that polls the shared child for exit and restarts it (bounded + backed off) if
/// it dies unexpectedly. Exits when the server is stopped (shutdown flag set, or the shared child /
/// `Manager` is gone) or the restart budget is spent.
///
/// Crucially it polls with `try_wait()` and holds the child lock only for the moment of the poll,
/// never across a blocking wait, so `stop()` can lock the same `Arc<Mutex<…>>` at any time and kill
/// the live child. The shutdown flag lets an intentional `stop()`-triggered exit be distinguished
/// from a crash, so shutdown never burns the restart budget or schedules a respawn.
fn spawn_monitor(
    child: Arc<Mutex<Option<SupervisedChild>>>,
    shutdown: Arc<AtomicBool>,
) -> Result<(), String> {
    std::thread::Builder::new()
        .name("stremiox-server-monitor".to_owned())
        .spawn(move || loop {
            // Poll the live child for exit. Hold the lock only for the non-blocking `try_wait()`, so
            // `stop()` can acquire it between polls to kill the child.
            let exit = match poll_child(&child) {
                ChildPoll::Running => None,
                ChildPoll::Exited(detail) => Some(detail),
                ChildPoll::Empty => return,
            };

            let detail = match exit {
                Some(detail) => detail,
                None => {
                    if shutdown.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(MONITOR_POLL_INTERVAL);
                    continue;
                }
            };

            // The child has exited. If a shutdown was requested, this is intentional; do NOT count
            // it as a crash and do NOT restart.
            if shutdown.load(Ordering::SeqCst) {
                return;
            }

            // Unexpected exit: apply the bounded-restart policy. Update crash bookkeeping in the
            // manager and decide whether we still have budget to restart.
            let restart_target = {
                let mut guard = MANAGER
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                let manager = match guard.as_mut() {
                    Some(manager)
                        if !shutdown.load(Ordering::SeqCst)
                            && Arc::ptr_eq(&manager.shutdown, &shutdown)
                            && Arc::ptr_eq(&manager.child, &child) =>
                    {
                        manager
                    }
                    None => return,    // stopped while we polled
                    Some(_) => return, // a newer manager generation replaced this monitor
                };

                // Reset the crash window if the last boot survived it (a healthy long-running server).
                if manager.window_start.elapsed() > RESTART_WINDOW {
                    manager.restarts = 0;
                    manager.window_start = Instant::now();
                }
                manager.restarts += 1;
                if manager.restarts > MAX_RESTARTS {
                    set_state(ServerState::Failed {
                        reason: format!("server crashed repeatedly ({detail}); giving up"),
                    });
                    return;
                }
                (
                    manager.node_bin.clone(),
                    manager.server_js.clone(),
                    manager.home.clone(),
                    u64::from(manager.restarts).max(1),
                )
            };
            let (node_bin, server_js, home, backoff) = restart_target;

            // Brief monotonic backoff so a fast crash-loop doesn't peg a CPU. Re-check the shutdown
            // flag afterwards so a `stop()` racing the backoff doesn't trigger a respawn.
            std::thread::sleep(Duration::from_millis(500 * backoff));
            if shutdown.load(Ordering::SeqCst) {
                return;
            }

            match spawn_child(&node_bin, &server_js, &home) {
                Ok((new_child, new_health_token)) => {
                    // Park the fresh child back in the shared slot, unless `stop()` won the race
                    // (shutdown set, slot already filled, or the manager vanished). In every
                    // lose-the-race case we kill the child we just spawned rather than orphan it;
                    // otherwise a `stop()` that ran during the backoff would leave a node process
                    // holding the port. A poisoned slot is recovered so its existing child remains
                    // reachable for teardown.
                    let mut start_error = None;
                    let orphan: Option<SupervisedChild> = if shutdown.load(Ordering::SeqCst) {
                        Some(new_child)
                    } else {
                        let mut slot = child
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        if slot.is_none() {
                            *slot = Some(new_child);
                            match slot
                                .as_mut()
                                .expect("replacement was parked before supervisor start")
                                .start()
                            {
                                Ok(()) => None,
                                Err(error) => {
                                    start_error =
                                        Some(format!("restart supervisor start failed: {error}"));
                                    slot.take()
                                }
                            }
                        } else {
                            // Slot already repopulated (shouldn't happen): do not leak the extra.
                            Some(new_child)
                        }
                    };

                    if let Some(child) = orphan {
                        kill_child(child);
                        if let Some(reason) = start_error {
                            set_monitor_failure(&shutdown, reason);
                        }
                        return;
                    }

                    // Child is parked in the shared slot. Re-check shutdown (a `stop()` racing the
                    // park may have already emptied the slot expecting it empty) and confirm the
                    // manager still exists before publishing the replacement's owner token and
                    // announcing Running. If either lost, take the child back out and kill it so it
                    // cannot outlive the app or authenticate under stale ownership.
                    let still_live = if shutdown.load(Ordering::SeqCst) {
                        false
                    } else {
                        let mut guard = MANAGER
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner());
                        match guard.as_mut() {
                            Some(manager)
                                if !shutdown.load(Ordering::SeqCst)
                                    && Arc::ptr_eq(&manager.shutdown, &shutdown)
                                    && Arc::ptr_eq(&manager.child, &child) =>
                            {
                                manager.health_token = new_health_token;
                                set_state(ServerState::Running);
                                true
                            }
                            None | Some(_) => false,
                        }
                    };
                    if still_live {
                        continue;
                    }
                    let parked = child
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .take();
                    if let Some(child) = parked {
                        kill_child(child);
                    }
                    return;
                }
                Err(err) => {
                    set_monitor_failure(&shutdown, format!("restart failed: {err}"));
                    return;
                }
            }
        })
        .map(|_| ())
        .map_err(|error| format!("failed to start server monitor: {error}"))
}

fn set_monitor_failure(shutdown: &Arc<AtomicBool>, reason: String) {
    if shutdown.load(Ordering::SeqCst) {
        return;
    }
    let guard = MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if guard.as_ref().is_some_and(|manager| {
        Arc::ptr_eq(&manager.shutdown, shutdown) && !shutdown.load(Ordering::SeqCst)
    }) {
        set_state(ServerState::Failed { reason });
    }
}

enum ChildPoll {
    Running,
    Exited(String),
    Empty,
}

/// Poll the child and clear the shared slot atomically when it exits. The monitor must leave the slot
/// empty before attempting a restart, otherwise the replacement process is treated as an orphan and
/// killed immediately.
fn poll_child(child: &Arc<Mutex<Option<SupervisedChild>>>) -> ChildPoll {
    let mut guard = child
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let result = match guard.as_mut() {
        Some(c) => c.try_wait(),
        None => return ChildPoll::Empty,
    };
    match result {
        Ok(None) => ChildPoll::Running,
        Ok(Some(status)) => {
            guard.take();
            ChildPoll::Exited(format!("exit {status}"))
        }
        Err(err) => {
            if let Some(child) = guard.take() {
                kill_child(child);
            }
            ChildPoll::Exited(format!("wait error: {err}"))
        }
    }
}

/// Force-kill a child and reap it. Used by both `stop()` and the monitor's shutdown-race path so we
/// never leave a node process holding the port.
fn kill_child(child: SupervisedChild) {
    child.shutdown_and_wait();
}

/// Stop the server supervisor and monitoring. Closing its ownership pipe makes the helper kill and
/// wait node; the same EOF occurs if the app process disappears. Idempotent.
///
/// The supervisor lives in a shared slot rather than on the monitor thread's stack, so explicit stop
/// can always take it and close the pipe. The shutdown flag is raised first so the monitor treats the
/// resulting exit as intentional, not a crash to restart.
pub fn stop() {
    // Pull the shared child slot + shutdown flag out of the manager, then drop the manager. We do the
    // actual kill without holding the MANAGER lock so we never block app exit on a wedged child.
    let shared = MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take()
        .map(|manager| (manager.child, manager.shutdown));

    if let Some((child, shutdown)) = shared {
        // Tell the monitor any exit from here on is intentional, not a crash to restart.
        shutdown.store(true, Ordering::SeqCst);
        // Take the live child out of the shared slot and kill it. After this the slot is `None`, so
        // the monitor's next poll sees no child and exits.
        let live = child
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .take();
        if let Some(child) = live {
            kill_child(child);
        }
    }

    set_state(ServerState::Disabled {
        reason: "stopped".to_owned(),
    });
}

/// Owner-authenticated readiness probe for the currently managed child. A bare TCP listener, a
/// stale server from another app launch, or a generic HTTP 200 cannot pass: the listener must prove
/// possession of this child's secret over a fresh random challenge. The full connect/write/read
/// exchange shares one wall-clock bound.
pub fn is_listening() -> bool {
    let token = MANAGER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .as_ref()
        .map(|manager| manager.health_token);
    token.is_some_and(|token| {
        let addr = SocketAddr::from(([127, 0, 0, 1], PORT));
        authenticated_health_check(addr, &token)
    })
}

fn authenticated_health_check(addr: SocketAddr, token: &HealthToken) -> bool {
    let deadline = Instant::now() + HEALTH_IO_TIMEOUT;
    let mut challenge = [0u8; HEALTH_SECRET_BYTES];
    if getrandom::fill(&mut challenge).is_err() {
        return false;
    }
    let challenge_hex = hex_encode(&challenge);

    let Some(connect_timeout) = remaining_timeout(deadline) else {
        return false;
    };
    let Ok(mut stream) = TcpStream::connect_timeout(&addr, connect_timeout) else {
        return false;
    };
    let Some(io_timeout) = remaining_timeout(deadline) else {
        return false;
    };
    if stream.set_read_timeout(Some(io_timeout)).is_err()
        || stream.set_write_timeout(Some(io_timeout)).is_err()
    {
        return false;
    }

    let request = format!(
        "GET {HEALTH_PATH} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n{HEALTH_CHALLENGE_HEADER}: {challenge_hex}\r\nConnection: close\r\n\r\n"
    );
    if stream.write_all(request.as_bytes()).is_err() || stream.flush().is_err() {
        return false;
    }

    let Some(proof) = read_health_proof(&mut stream, deadline) else {
        return false;
    };
    let mut mac = HealthMac::new_from_slice(token).expect("HMAC accepts a 32-byte key");
    mac.update(challenge_hex.as_bytes());
    mac.verify_slice(&proof).is_ok()
}

fn remaining_timeout(deadline: Instant) -> Option<Duration> {
    let remaining = deadline.checked_duration_since(Instant::now())?;
    (!remaining.is_zero()).then_some(remaining)
}

/// Read one small, fixed-length HTTP response under the shared wall deadline. The preload always
/// returns a Content-Length body and closes the connection; chunking, duplicate/missing lengths,
/// oversized headers, extra bytes, malformed hex, and timeouts all fail closed.
fn read_health_proof(stream: &mut TcpStream, deadline: Instant) -> Option<[u8; 32]> {
    let mut response = Vec::with_capacity(256);
    loop {
        let remaining = remaining_timeout(deadline)?;
        stream.set_read_timeout(Some(remaining)).ok()?;

        let mut chunk = [0u8; 256];
        let read = match stream.read(&mut chunk) {
            Ok(0) => return None,
            Ok(read) => read,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return None;
            }
            Err(_) => return None,
        };
        if response.len() + read > HEALTH_RESPONSE_LIMIT {
            return None;
        }
        response.extend_from_slice(&chunk[..read]);

        let Some(header_marker) = response.windows(4).position(|window| window == b"\r\n\r\n")
        else {
            continue;
        };
        let body_start = header_marker + 4;
        let headers = std::str::from_utf8(&response[..header_marker]).ok()?;
        if !health_headers_are_valid(headers) {
            return None;
        }
        let expected_end = body_start + HEALTH_PROOF_HEX_BYTES;
        if response.len() < expected_end {
            continue;
        }
        if response.len() != expected_end {
            return None;
        }
        // The authenticated route promises `Connection: close`; require actual EOF before
        // accepting so a valid prefix followed by smuggled/trailing bytes cannot authenticate.
        let remaining = remaining_timeout(deadline)?;
        stream.set_read_timeout(Some(remaining)).ok()?;
        let mut trailing = [0u8; 1];
        match stream.read(&mut trailing) {
            Ok(0) => return decode_health_proof(&response[body_start..expected_end]),
            Ok(_) => return None,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                return None;
            }
            Err(_) => return None,
        }
    }
}

fn health_headers_are_valid(headers: &str) -> bool {
    let mut lines = headers.split("\r\n");
    if lines.next() != Some("HTTP/1.1 200 OK") {
        return false;
    }

    let mut content_length = None;
    let mut content_type = None;
    let mut cache_control = None;
    let mut connection = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            return false;
        };
        let value = value.trim();
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return false;
        } else if name.eq_ignore_ascii_case("content-length") {
            if content_length.replace(value).is_some() {
                return false;
            }
        } else if name.eq_ignore_ascii_case("content-type") {
            if content_type.replace(value).is_some() {
                return false;
            }
        } else if name.eq_ignore_ascii_case("cache-control") {
            if cache_control.replace(value).is_some() {
                return false;
            }
        } else if name.eq_ignore_ascii_case("connection") && connection.replace(value).is_some() {
            return false;
        }
    }
    content_length == Some("64")
        && content_type.is_some_and(|value| value.eq_ignore_ascii_case("text/plain"))
        && cache_control.is_some_and(|value| value.eq_ignore_ascii_case("no-store"))
        && connection.is_some_and(|value| value.eq_ignore_ascii_case("close"))
}

fn decode_health_proof(encoded: &[u8]) -> Option<[u8; 32]> {
    if encoded.len() != HEALTH_PROOF_HEX_BYTES {
        return None;
    }
    let mut proof = [0u8; 32];
    for (index, pair) in encoded.chunks_exact(2).enumerate() {
        proof[index] = (hex_nibble(pair[0])? << 4) | hex_nibble(pair[1])?;
    }
    Some(proof)
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    /// Serializes tests that mutate the global `MANAGER`/`STATE`, since cargo runs tests in parallel
    /// threads and these share process-global state.
    static TEST_GUARD: Mutex<()> = Mutex::new(());

    #[test]
    fn base_url_is_loopback_on_the_expected_port() {
        assert_eq!(base_url(), "http://127.0.0.1:11470");
    }

    #[test]
    fn node_binary_name_matches_the_host_target() {
        let name = node_binary_name();
        // Sanity: the name the fetch script stages for this host must be what we look up. We can't
        // assert the exact string per-platform here without duplicating cfg, but it must be one of
        // the known staged names and must carry the host OS marker.
        let known = [
            "node-darwin-arm64",
            "node-darwin-x64",
            "node-linux-x64",
            "node-linux-arm64",
            "node-win-x64.exe",
        ];
        assert!(known.contains(&name), "unexpected node binary name: {name}");
    }

    #[test]
    fn json_string_escapes_windows_paths_for_the_preload() {
        // Backslashes in a Windows path must survive into valid JS string literals.
        let encoded = json_string(r"C:\Users\me\app\server.log");
        assert!(encoded.starts_with('"') && encoded.ends_with('"'));
        assert!(encoded.contains(r"\\Users\\me"));
    }

    #[test]
    fn health_tokens_come_from_fresh_full_width_random_values() {
        let first = fresh_health_token().expect("first health token");
        let second = fresh_health_token().expect("second health token");
        assert_ne!(
            first, second,
            "each child launch must rotate owner identity"
        );
        assert_eq!(hex_encode(&first).len(), HEALTH_SECRET_BYTES * 2);
        assert!(
            hex_encode(&first)
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase()),
            "the child environment receives canonical lowercase hex"
        );
    }

    #[test]
    fn status_defaults_to_disabled_before_start() {
        // The static initializer reports a disabled/not-started state until start() runs.
        match status() {
            ServerState::Disabled { .. } => {}
            other => panic!("expected Disabled before start, got {other:?}"),
        }
    }

    /// Spawn a long-lived dummy process standing in for the node server, so the kill-path tests have a
    /// real OS child to reap without needing the bundled node runtime.
    fn spawn_dummy() -> Child {
        #[cfg(not(target_os = "windows"))]
        {
            Command::new("sleep")
                .arg("600")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn sleep")
        }
        #[cfg(target_os = "windows")]
        {
            // `ping -n 600 localhost` blocks ~600s without extra tooling.
            Command::new("cmd")
                .args(["/C", "ping", "-n", "600", "127.0.0.1"])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn ping")
        }
    }

    /// True while the process with `pid` still exists. Used to prove `stop()` actually reaped the
    /// child rather than just clearing a guard.
    fn pid_is_alive(pid: u32) -> bool {
        #[cfg(not(target_os = "windows"))]
        {
            // `kill -0` probes for existence without sending a real signal: Ok exit => still alive.
            Command::new("kill")
                .arg("-0")
                .arg(pid.to_string())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
        #[cfg(target_os = "windows")]
        {
            let out = Command::new("tasklist")
                .args(["/FI", &format!("PID eq {pid}"), "/NH"])
                .output()
                .expect("tasklist");
            String::from_utf8_lossy(&out.stdout).contains(&pid.to_string())
        }
    }

    /// Install a dummy child into the global MANAGER the way `start()` does, minus the real node
    /// spawn, and return the child's PID. The monitor is intentionally NOT spawned here so the test
    /// owns the lifecycle deterministically.
    fn install_dummy_manager() -> u32 {
        let child = spawn_dummy();
        let pid = child.id();
        let mut guard = MANAGER.lock().expect("manager lock");
        *guard = Some(Manager {
            child: Arc::new(Mutex::new(Some(SupervisedChild::unsupervised(child)))),
            shutdown: Arc::new(AtomicBool::new(false)),
            node_bin: PathBuf::from("dummy-node"),
            server_js: PathBuf::from("dummy-server.cjs"),
            home: std::env::temp_dir(),
            health_token: [7; HEALTH_SECRET_BYTES],
            restarts: 0,
            window_start: Instant::now(),
        });
        pid
    }

    /// Core regression test for the orphaned-node bug: after `stop()`, the child the manager owned is
    /// actually killed (not merely forgotten), so nothing is left holding the port. Also covers the
    /// shared-slot wiring (`stop()` can reach a child that lives in the `Arc<Mutex<…>>`) and `stop()`
    /// idempotency.
    #[test]
    fn stop_kills_the_managed_child_and_is_idempotent() {
        let _g = TEST_GUARD.lock().unwrap_or_else(|p| p.into_inner());
        let pid = install_dummy_manager();
        assert!(
            pid_is_alive(pid),
            "dummy child should be running before stop()"
        );

        stop();

        // Give the OS a moment to tear the process down, then assert it's gone.
        let mut alive = true;
        for _ in 0..50 {
            if !pid_is_alive(pid) {
                alive = false;
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(
            !alive,
            "stop() must kill the managed child (pid {pid} still alive)"
        );

        // Manager is cleared and a second stop() is a harmless no-op.
        assert!(MANAGER.lock().expect("manager lock").is_none());
        stop();

        match status() {
            ServerState::Disabled { .. } => {}
            other => panic!("expected Disabled after stop, got {other:?}"),
        }
    }

    /// `stop()` raises the shutdown flag so the monitor treats the kill as intentional and never
    /// schedules a restart. We assert the flag is observed as set on the shared handle `stop()` uses.
    #[test]
    fn stop_signals_shutdown_so_kill_is_not_treated_as_a_crash() {
        let _g = TEST_GUARD.lock().unwrap_or_else(|p| p.into_inner());
        let _pid = install_dummy_manager();
        // Grab the shutdown handle the manager shares with the (would-be) monitor.
        let shutdown = MANAGER
            .lock()
            .expect("manager lock")
            .as_ref()
            .map(|m| Arc::clone(&m.shutdown))
            .expect("manager present");
        assert!(
            !shutdown.load(Ordering::SeqCst),
            "shutdown should start clear"
        );

        stop();

        assert!(
            shutdown.load(Ordering::SeqCst),
            "stop() must set the shutdown flag so the monitor does not restart the killed child"
        );
    }

    #[test]
    fn exited_child_is_removed_before_restart() {
        let child = {
            #[cfg(not(target_os = "windows"))]
            {
                Command::new("true").spawn().expect("spawn true")
            }
            #[cfg(target_os = "windows")]
            {
                Command::new("cmd")
                    .args(["/C", "exit", "0"])
                    .spawn()
                    .expect("spawn exit")
            }
        };
        let shared = Arc::new(Mutex::new(Some(SupervisedChild::unsupervised(child))));
        let mut exited = false;
        for _ in 0..50 {
            match poll_child(&shared) {
                ChildPoll::Running => std::thread::sleep(Duration::from_millis(10)),
                ChildPoll::Exited(_) => {
                    exited = true;
                    break;
                }
                ChildPoll::Empty => break,
            }
        }
        assert!(exited, "dummy child should exit during the test");
        assert!(
            shared.lock().expect("child lock").is_none(),
            "the dead child must not occupy the slot used by the replacement"
        );
    }

    enum TestHealthReply {
        Owned(HealthToken),
        UnauthenticatedOk,
        Silent,
    }

    fn spawn_test_health_server(
        reply: TestHealthReply,
    ) -> (SocketAddr, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind((HOST, 0)).expect("bind test health listener");
        let addr = listener.local_addr().expect("test listener address");
        let handle = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept health probe");
            stream
                .set_read_timeout(Some(Duration::from_secs(1)))
                .expect("bound test request read");

            if matches!(reply, TestHealthReply::Silent) {
                std::thread::sleep(Duration::from_millis(700));
                return;
            }

            let mut request = Vec::new();
            while request.len() < 1024 && !request.windows(4).any(|window| window == b"\r\n\r\n") {
                let mut chunk = [0u8; 256];
                let read = stream.read(&mut chunk).expect("read health request");
                assert_ne!(read, 0, "health request closed before headers");
                request.extend_from_slice(&chunk[..read]);
            }
            let request = std::str::from_utf8(&request).expect("ASCII health request");
            assert!(
                request.starts_with(&format!("GET {HEALTH_PATH} HTTP/1.1\r\n")),
                "probe uses only the private health route"
            );
            let challenge = request
                .lines()
                .filter_map(|line| line.split_once(':'))
                .find_map(|(name, value)| {
                    name.eq_ignore_ascii_case(HEALTH_CHALLENGE_HEADER)
                        .then(|| value.trim())
                })
                .expect("health challenge header");

            let body = match reply {
                TestHealthReply::Owned(token) => {
                    let mut mac =
                        HealthMac::new_from_slice(&token).expect("HMAC accepts test owner key");
                    mac.update(challenge.as_bytes());
                    hex_encode(&mac.finalize().into_bytes())
                }
                TestHealthReply::UnauthenticatedOk => "0".repeat(HEALTH_PROOF_HEX_BYTES),
                TestHealthReply::Silent => unreachable!(),
            };
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .expect("write health response");
        });
        (addr, handle)
    }

    #[test]
    fn authenticated_health_check_accepts_only_the_owned_listener() {
        let owner = fresh_health_token().expect("owner token");
        let (owned_addr, owned_server) = spawn_test_health_server(TestHealthReply::Owned(owner));
        assert!(
            authenticated_health_check(owned_addr, &owner),
            "matching child key must authenticate readiness"
        );
        owned_server.join().expect("owned test server");

        let impostor_key = fresh_health_token().expect("impostor token");
        let (wrong_addr, wrong_server) =
            spawn_test_health_server(TestHealthReply::Owned(impostor_key));
        assert!(
            !authenticated_health_check(wrong_addr, &owner),
            "a listener proving a different launch key is stale or foreign"
        );
        wrong_server.join().expect("wrong-key test server");

        let (bare_addr, bare_server) = spawn_test_health_server(TestHealthReply::UnauthenticatedOk);
        assert!(
            !authenticated_health_check(bare_addr, &owner),
            "a generic HTTP 200 on the expected port is not readiness"
        );
        bare_server.join().expect("bare HTTP test server");
    }

    #[test]
    fn authenticated_health_check_has_one_bounded_wall_deadline() {
        let owner = fresh_health_token().expect("owner token");
        let (addr, silent_server) = spawn_test_health_server(TestHealthReply::Silent);
        let started = Instant::now();
        assert!(!authenticated_health_check(addr, &owner));
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "a silent listener must not hold the command thread indefinitely"
        );
        silent_server.join().expect("silent test server");
    }

    fn parse_raw_health_response(
        response: String,
        hold_open: bool,
    ) -> (Option<[u8; 32]>, Duration) {
        let listener = TcpListener::bind((HOST, 0)).expect("bind raw health listener");
        let addr = listener.local_addr().expect("raw health address");
        let sender = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept raw health parser");
            stream
                .write_all(response.as_bytes())
                .expect("write raw health response");
            if hold_open {
                std::thread::sleep(Duration::from_millis(700));
            }
        });
        let mut stream = TcpStream::connect(addr).expect("connect raw health parser");
        let started = Instant::now();
        let parsed = read_health_proof(&mut stream, Instant::now() + HEALTH_IO_TIMEOUT);
        let elapsed = started.elapsed();
        drop(stream);
        sender.join().expect("raw health response sender");
        (parsed, elapsed)
    }

    fn canonical_health_response(body: &str) -> String {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: 64\r\nConnection: close\r\n\r\n{body}"
        )
    }

    #[test]
    fn health_response_requires_exact_security_headers_and_canonical_body() {
        let valid_headers = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: 64\r\nConnection: close";
        assert!(health_headers_are_valid(valid_headers));
        for invalid in [
            "HTTP/1.1 200 OK\r\nCache-Control: no-store\r\nContent-Length: 64\r\nConnection: close",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: max-age=0\r\nContent-Length: 64\r\nConnection: close",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: 064\r\nConnection: close",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: 64\r\nConnection: keep-alive",
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nContent-Length: 64\r\nConnection: close\r\nTransfer-Encoding: chunked",
        ] {
            assert!(
                !health_headers_are_valid(invalid),
                "unexpectedly accepted headers: {invalid}"
            );
        }

        assert!(parse_raw_health_response(
            canonical_health_response(&"0".repeat(HEALTH_PROOF_HEX_BYTES)),
            false,
        )
        .0
        .is_some());
        assert!(parse_raw_health_response(
            canonical_health_response(&"A".repeat(HEALTH_PROOF_HEX_BYTES)),
            false,
        )
        .0
        .is_none());
        assert!(parse_raw_health_response(
            format!(
                "{}x",
                canonical_health_response(&"0".repeat(HEALTH_PROOF_HEX_BYTES))
            ),
            false,
        )
        .0
        .is_none());
    }

    #[test]
    fn health_response_requires_eof_within_the_shared_deadline() {
        let (parsed, elapsed) = parse_raw_health_response(
            canonical_health_response(&"0".repeat(HEALTH_PROOF_HEX_BYTES)),
            true,
        );
        assert!(parsed.is_none());
        assert!(
            elapsed < Duration::from_millis(650),
            "held-open response exceeded the bounded parser deadline: {elapsed:?}"
        );
    }

    #[test]
    fn generated_preload_proves_owner_identity_with_real_node_when_available() {
        let probe = TcpListener::bind((HOST, 0)).expect("reserve test node port");
        let port = probe.local_addr().expect("reserved node address").port();
        drop(probe);

        let directory = tempfile::tempdir().expect("preload test directory");
        let preload = write_preload(directory.path()).expect("write preload");
        let owner = fresh_health_token().expect("owner token");
        let script = format!(
            "if(process.env.{HEALTH_TOKEN_ENV}!==undefined)process.exit(42);require('http').createServer((_q,r)=>{{r.writeHead(500);r.end()}}).listen({port})"
        );
        let mut child = match Command::new("node")
            .arg("-r")
            .arg(&preload)
            .arg("-e")
            .arg(script)
            .env(HEALTH_TOKEN_ENV, hex_encode(&owner))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
        {
            Ok(child) => child,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return,
            Err(error) => panic!("spawn node preload test: {error}"),
        };

        let addr = SocketAddr::from(([127, 0, 0, 1], port));
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut authenticated = false;
        while Instant::now() < deadline {
            if authenticated_health_check(addr, &owner) {
                authenticated = true;
                break;
            }
            if child.try_wait().expect("poll node preload test").is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        let wrong_owner = fresh_health_token().expect("wrong owner token");
        let rejects_wrong_owner = !authenticated_health_check(addr, &wrong_owner);
        let _ = child.kill();
        let _ = child.wait();

        assert!(
            authenticated,
            "the emitted preload and Rust verifier must complete the same HMAC protocol"
        );
        assert!(
            rejects_wrong_owner,
            "the real preload must reject a different process identity"
        );
    }

    /// Parent ownership lives in the cross-platform Rust supervisor, not in a process.ppid heuristic
    /// that is ineffective on Windows. The preload retains only loopback pinning and health proof.
    #[test]
    fn write_preload_has_no_platform_specific_parent_watchdog() {
        let dir = std::env::temp_dir().join(format!("stremiox-preload-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mk tmp dir");
        let path = write_preload(&dir).expect("write preload");
        let js = std::fs::read_to_string(&path).expect("read preload");

        match Command::new("node").arg("--check").arg(&path).output() {
            Ok(output) => assert!(
                output.status.success(),
                "generated preload must parse as JavaScript: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => panic!("run node --check on generated preload: {error}"),
        }

        assert!(!js.contains("process.ppid"));
        assert!(
            js.contains("net.Server.prototype.listen"),
            "loopback-pin preload still present"
        );
        assert!(
            js.contains("delete process.env[HENV];"),
            "the owner key is removed from the child environment before server.cjs loads"
        );
        assert!(
            js.contains("crypto.createHmac('sha256',key).update(challenge,'ascii')"),
            "the health route proves key ownership over the caller's fresh challenge"
        );
        assert!(
            js.contains("req.url===HPATH"),
            "the health handler intercepts only its exact private route"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
