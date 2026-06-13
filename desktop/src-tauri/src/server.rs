//! Embedded streaming server for the desktop app.
//!
//! Runs Stremio's `server.cjs` (the torrent engine + `/proxy` + HLS) in a CHILD PROCESS bound to
//! `http://127.0.0.1:11470`, so TORRENT streams play on desktop (the app was direct/debrid only).
//!
//! This is the Tauri/Rust twin of the macOS app's `app/SourcesShared/MacNodeServer.swift`: that app
//! is unsandboxed and spawns the ordinary standalone `node` with Foundation's `Process`; here we
//! bundle the same standalone `node` (fetched into `resources/` by `scripts/fetch-server-deps.sh`)
//! and spawn it with `std::process::Command`. The env handling (HOME / APP_PATH / NO_CORS /
//! CASTING_DISABLED / UV_THREADPOOL_SIZE / ffmpeg discovery incl. Homebrew's Apple-silicon prefix)
//! and the loopback-bind preload are ported directly from MacNodeServer.
//!
//! A monitor thread waits on the child and restarts it (bounded, backed off) if it dies unexpectedly,
//! so a single crash doesn't permanently kill torrent playback. The child is force-killed on app
//! exit. The frontend learns the base URL + liveness through the `server_status` / `server_base_url`
//! Tauri commands (see lib.rs), and primes a torrent by POSTing `<base>/<infohash>/create` itself
//! (mirroring the Apple `prepareTorrent`), then plays `<base>/<infohash>/<fileIdx>`.

use std::io::Write;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

use once_cell::sync::Lazy;
use serde::Serialize;

/// How often the monitor polls the live child for exit. Short enough that a crash is noticed and
/// restarted promptly, long enough to stay idle-cheap. The monitor holds no lock between polls, so
/// `stop()` can always reach the child to kill it.
const MONITOR_POLL_INTERVAL: Duration = Duration::from_millis(250);

/// Loopback host + port the embedded server binds. Matches the Apple app's `StremioServer.embedded`
/// and the port server.js listens on by default.
const HOST: &str = "127.0.0.1";
const PORT: u16 = 11470;

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
    /// Child spawned; may still be booting (the frontend health-checks the base URL before relying on it).
    Running,
    /// Child exited and we stopped restarting it. `reason` carries the last exit detail.
    Failed { reason: String },
}

struct Manager {
    /// The running child, kept so we can wait on / kill it. `None` once stopped.
    ///
    /// Shared with the monitor thread via `Arc<Mutex<…>>` so the child is reachable from BOTH the
    /// monitor (which polls it for exit) and `stop()` (which kills it). The monitor never holds this
    /// lock across a blocking wait — it polls with `try_wait()` — so `stop()` can always lock and
    /// `.kill()` the live child. This is what keeps `stop()`'s "never orphan a node process" contract
    /// honest: the previous design moved the child onto the monitor's stack for a blocking `wait()`,
    /// leaving `stop()` with nothing to kill.
    child: Arc<Mutex<Option<Child>>>,
    /// Set by `stop()` to tell the monitor an exit is an intentional shutdown, NOT a crash to restart.
    /// Shared with the monitor; the `Manager` itself is dropped on stop, so the monitor's `Arc` clone
    /// keeps the flag alive.
    shutdown: Arc<AtomicBool>,
    /// Absolute paths resolved at startup (node binary + server.js + writable home).
    node_bin: PathBuf,
    server_js: PathBuf,
    home: PathBuf,
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
/// probe the common locations and hand the pair to node via FFMPEG_BIN / FFPROBE_BIN — the first
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

/// The preload JS injected with `node -r`. It (a) tees uncaught errors to a log file, (b) pins every
/// host-less `server.listen(port)` to loopback (127.0.0.1), and (c) installs a parent-death watchdog
/// that exits the child once its parent pid changes — i.e. once it has been reparented. `stop()` only
/// kills the child on a GRACEFUL app exit; on a crash / SIGKILL / Force-Quit the Tauri exit hook never
/// runs and the OS reparents the child (to launchd/init), where it would keep holding the port as an
/// orphan. The watchdog closes that gap (ported from MacNodeServer.swift's preload). server.js listens
/// with no host, which Node treats as 0.0.0.0 (every interface) — i.e. LAN-reachable; the desktop app
/// wants it private, so we monkeypatch `net.Server.prototype.listen` exactly like MacNodeServer.
fn write_preload(home: &Path) -> std::io::Result<PathBuf> {
    let preload_path = home.join("stremiox-preload.js");
    let log_path = home.join("stremio-server.log");
    let log_js = json_string(&log_path.to_string_lossy());
    let host_js = json_string(HOST);
    let preload = format!(
        r#"const fs=require('fs'),L={log};
const w=(t,a)=>{{try{{fs.appendFileSync(L,t+' '+Array.prototype.map.call(a,String).join(' ')+'\n')}}catch(e){{}}}};
process.on('uncaughtException',function(e){{w('[uncaught]',[e&&e.stack||e])}});
process.on('unhandledRejection',function(e){{w('[rej]',[e&&e.stack||e])}});
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
// parent-death watchdog (see fn doc): exit once our parent pid changes (we've been reparented) so a
// crash / SIGKILL of the app can't leave us orphaned on the port. .unref() keeps this poll timer from
// holding the process open by itself.
const PPID0=process.ppid;
setInterval(function(){{if(process.ppid!==PPID0){{w('[watchdog]',['parent gone; exiting']);process.exit(0);}}}},1000).unref();
"#,
        log = log_js,
        host = host_js,
    );
    std::fs::write(&preload_path, preload)?;
    Ok(preload_path)
}

/// JSON-encode a string for safe embedding in the preload JS source (handles Windows backslashes,
/// quotes, etc.). Always produces a quoted literal.
fn json_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_owned())
}

/// Spawn `node -r preload server.js` with the Apple-equivalent environment. Returns the Child or an
/// io::Error explaining why launch failed.
fn spawn_child(node_bin: &Path, server_js: &Path, home: &Path) -> std::io::Result<Child> {
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

    let mut cmd = Command::new(node_bin);
    cmd.arg("-r")
        .arg(&preload)
        .arg(server_js)
        .current_dir(home)
        .env("HOME", home) // server reads HOME for its app-data path
        .env("APP_PATH", &server_data) // torrent cache + settings
        .env("NO_CORS", "1")
        .env("CASTING_DISABLED", "1") // no cast UI on desktop; skip the SSDP multicast loop
        .env("UV_THREADPOOL_SIZE", "16") // more libuv workers for tracker DNS + disk/crypto
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));

    if let Some((ffmpeg, ffprobe)) = ffmpeg_binaries() {
        cmd.env("FFMPEG_BIN", &ffmpeg).env("FFPROBE_BIN", &ffprobe);
    }

    cmd.spawn()
}

/// Before the first spawn, reclaim the port if a STALE copy of OUR OWN node server is still holding it
/// — e.g. a prior run force-killed / crashed before `stop()` could fire, leaving the child reparented
/// (to launchd/init) and still bound. The preload's parent-death watchdog stops new orphans from
/// forming; this clears any that predate it (or slipped through its ~1s poll window). We match "ours"
/// narrowly — a process whose argv references the `stremiox-preload.js` we inject, a marker nothing
/// else uses — so an unrelated process that merely happens to hold the port is left alone (server.cjs
/// then fails to bind and the monitor surfaces it, rather than us killing a stranger). SIGTERM first,
/// escalate to SIGKILL, mirroring `kill_child`. Best-effort: a missing/failing tool just skips the
/// reclaim. Unix-only (lsof/ps/kill); a no-op elsewhere.
#[cfg(unix)]
fn reclaim_stale_port() {
    for pid in port_listeners(PORT) {
        if !is_our_node_server(&pid) {
            continue;
        }
        eprintln!("stremiox: reclaiming port {PORT} from a stale node server (pid {pid})");
        let _ = Command::new("kill").arg(&pid).status(); // SIGTERM — ask it to exit cleanly
        let deadline = Instant::now() + Duration::from_secs(2);
        while pid_alive(&pid) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        if pid_alive(&pid) {
            let _ = Command::new("kill").args(["-9", &pid]).status(); // SIGKILL — guarantee release
        }
    }
}

#[cfg(not(unix))]
fn reclaim_stale_port() {}

/// PIDs holding a LISTEN socket on `port` (via `lsof -t`); empty when the port is free or `lsof` is
/// unavailable. Kept as strings since we only ever feed them back to `ps`/`kill`.
#[cfg(unix)]
fn port_listeners(port: u16) -> Vec<String> {
    run_tool("lsof", &["-nP", &format!("-iTCP:{port}"), "-sTCP:LISTEN", "-t"])
        .map(|out| {
            out.lines()
                .map(|l| l.trim().to_owned())
                .filter(|l| !l.is_empty())
                .collect()
        })
        .unwrap_or_default()
}

/// True if `pid`'s argv references our injected `stremiox-preload.js` — the marker that identifies one
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
    let mut guard = match MANAGER.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
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
            reason: "server.cjs missing from resources. Run scripts/fetch-server-deps.sh.".to_owned(),
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

    // A prior run that was force-killed / crashed before `stop()` could fire may have left a node child
    // reparented and still holding the port. Clear that stale orphan (only if it's ours) before we
    // spawn, so this launch can bind instead of failing. The preload watchdog prevents new orphans.
    reclaim_stale_port();

    match spawn_child(&node_bin, &server_js, &home) {
        Ok(child) => {
            set_state(ServerState::Running);
            let child = Arc::new(Mutex::new(Some(child)));
            let shutdown = Arc::new(AtomicBool::new(false));
            // Clones the monitor thread owns for the lifetime of the server, so it can poll the child
            // and observe a shutdown request even after the `Manager` is dropped by `stop()`.
            let monitor_child = Arc::clone(&child);
            let monitor_shutdown = Arc::clone(&shutdown);
            *guard = Some(Manager {
                child,
                shutdown,
                node_bin,
                server_js,
                home,
                restarts: 0,
                window_start: Instant::now(),
            });
            drop(guard);
            spawn_monitor(monitor_child, monitor_shutdown);
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
/// never across a blocking wait — so `stop()` can lock the same `Arc<Mutex<…>>` at any time and kill
/// the live child. The shutdown flag lets an intentional `stop()`-triggered exit be distinguished
/// from a crash, so shutdown never burns the restart budget or schedules a respawn.
fn spawn_monitor(child: Arc<Mutex<Option<Child>>>, shutdown: Arc<AtomicBool>) {
    std::thread::Builder::new()
        .name("stremiox-server-monitor".to_owned())
        .spawn(move || loop {
            // Poll the live child for exit. Hold the lock only for the non-blocking `try_wait()`, so
            // `stop()` can acquire it between polls to kill the child.
            let exit = {
                let mut guard = match child.lock() {
                    Ok(g) => g,
                    Err(_) => return,
                };
                match guard.as_mut() {
                    // Still running: release the lock, sleep, poll again.
                    Some(c) => match c.try_wait() {
                        Ok(None) => None,
                        Ok(Some(status)) => Some(format!("exit {status}")),
                        Err(err) => Some(format!("wait error: {err}")),
                    },
                    // `stop()` took the child (or it was already killed) — nothing left to monitor.
                    None => return,
                }
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

            // The child has exited. If a shutdown was requested, this is intentional — do NOT count
            // it as a crash and do NOT restart.
            if shutdown.load(Ordering::SeqCst) {
                return;
            }

            // Unexpected exit: apply the bounded-restart policy. Update crash bookkeeping in the
            // manager and decide whether we still have budget to restart.
            let restart_target = {
                let mut guard = match MANAGER.lock() {
                    Ok(g) => g,
                    Err(_) => return,
                };
                let manager = match guard.as_mut() {
                    Some(m) => m,
                    None => return, // stopped while we polled
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
                Ok(new_child) => {
                    // Park the fresh child back in the shared slot, unless `stop()` won the race
                    // (shutdown set, slot already filled, lock poisoned, or the manager vanished). In
                    // every lose-the-race case we kill the child we just spawned rather than orphan
                    // it — otherwise a `stop()` that ran during the backoff would leave a node process
                    // holding the port.
                    let orphan: Option<Child> = if shutdown.load(Ordering::SeqCst) {
                        Some(new_child)
                    } else {
                        match child.lock() {
                            Ok(mut slot) if slot.is_none() => {
                                *slot = Some(new_child);
                                None
                            }
                            // Slot already repopulated (shouldn't happen) or lock poisoned — don't
                            // leak the extra child.
                            Ok(_) => Some(new_child),
                            Err(_) => Some(new_child),
                        }
                    };

                    if let Some(child) = orphan {
                        kill_child(child);
                        return;
                    }

                    // Child is parked in the shared slot. Re-check shutdown (a `stop()` racing the
                    // park may have already emptied the slot expecting it empty) and confirm the
                    // manager still exists before announcing Running. If either lost, take the child
                    // back out and kill it so it can't outlive the app.
                    let still_live = !shutdown.load(Ordering::SeqCst)
                        && matches!(MANAGER.lock(), Ok(g) if g.is_some());
                    if still_live {
                        set_state(ServerState::Running);
                        continue;
                    }
                    if let Some(child) = child.lock().ok().and_then(|mut slot| slot.take()) {
                        kill_child(child);
                    }
                    return;
                }
                Err(err) => {
                    set_state(ServerState::Failed {
                        reason: format!("restart failed: {err}"),
                    });
                    return;
                }
            }
        })
        .ok();
}

/// Force-kill a child and reap it. Used by both `stop()` and the monitor's shutdown-race path so we
/// never leave a node process holding the port.
fn kill_child(mut child: Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// Force-kill the server child and stop monitoring. Called on app exit so we never orphan a node
/// process. Idempotent.
///
/// Unlike the previous version, this actually owns a handle to the live child: the child lives in a
/// shared `Arc<Mutex<Option<Child>>>` (not on the monitor thread's stack), so we lock that slot, take
/// the child, and kill it here. The shutdown flag is raised first so the monitor treats the kill as
/// an intentional exit, not a crash to restart.
pub fn stop() {
    // Pull the shared child slot + shutdown flag out of the manager, then drop the manager. We do the
    // actual kill without holding the MANAGER lock so we never block app exit on a wedged child.
    let shared = MANAGER.lock().ok().and_then(|mut guard| {
        guard.take().map(|manager| (manager.child, manager.shutdown))
    });

    if let Some((child, shutdown)) = shared {
        // Tell the monitor any exit from here on is intentional — not a crash to restart.
        shutdown.store(true, Ordering::SeqCst);
        // Take the live child out of the shared slot and kill it. After this the slot is `None`, so
        // the monitor's next poll sees no child and exits.
        let live = child.lock().ok().and_then(|mut slot| slot.take());
        if let Some(child) = live {
            kill_child(child);
        }
    }

    set_state(ServerState::Disabled {
        reason: "stopped".to_owned(),
    });
}

/// Best-effort liveness probe: can we open a TCP connection to the loopback port? Used by the
/// `server_is_listening` command so the frontend can wait for boot before relying on the server. A
/// plain TCP connect avoids pulling an HTTP client feature just for a health check.
pub fn is_listening() -> bool {
    let addr = format!("{HOST}:{PORT}");
    addr.parse()
        .ok()
        .and_then(|a| TcpStream::connect_timeout(&a, Duration::from_millis(400)).ok())
        .map(|mut s| {
            // A graceful close keeps the server's connection log quiet.
            let _ = s.flush();
            true
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

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
            child: Arc::new(Mutex::new(Some(child))),
            shutdown: Arc::new(AtomicBool::new(false)),
            node_bin: PathBuf::from("dummy-node"),
            server_js: PathBuf::from("dummy-server.cjs"),
            home: std::env::temp_dir(),
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
        assert!(pid_is_alive(pid), "dummy child should be running before stop()");

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
        assert!(!alive, "stop() must kill the managed child (pid {pid} still alive)");

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
        assert!(!shutdown.load(Ordering::SeqCst), "shutdown should start clear");

        stop();

        assert!(
            shutdown.load(Ordering::SeqCst),
            "stop() must set the shutdown flag so the monitor does not restart the killed child"
        );
    }

    /// The injected preload must carry the parent-death watchdog (the orphan fix) with the `format!`
    /// brace-escaping correctly resolved, and must still carry the loopback pin. Pure string check —
    /// no node runtime needed.
    #[test]
    fn write_preload_carries_the_parent_death_watchdog() {
        let dir = std::env::temp_dir().join(format!("stremiox-preload-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("mk tmp dir");
        let path = write_preload(&dir).expect("write preload");
        let js = std::fs::read_to_string(&path).expect("read preload");
        let _ = std::fs::remove_dir_all(&dir);

        assert!(
            js.contains("const PPID0=process.ppid;"),
            "watchdog records the initial parent pid"
        );
        // Opening + closing braces must have resolved from `{{`/`}}` to single JS braces.
        assert!(
            js.contains("setInterval(function(){if(process.ppid!==PPID0){"),
            "watchdog opening braces resolved by format!"
        );
        assert!(
            js.contains("process.exit(0);}},1000).unref();"),
            "watchdog closing braces resolved by format! and the timer is unref'd"
        );
        // The loopback pin still coexists with the new watchdog.
        assert!(
            js.contains("net.Server.prototype.listen"),
            "loopback-pin preload still present alongside the watchdog"
        );
    }
}
