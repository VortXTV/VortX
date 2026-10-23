//! The VortX streaming server, running inside the desktop app process.
//!
//! The same engine server the Apple and Android apps embed (vortx-core's `vortx-streaming-server`): it
//! fetches torrent pieces and serves the selected file over HTTP for mpv. It binds an ephemeral port on
//! 127.0.0.1 only, so nothing outside this machine can reach it and no other process can stand in for it:
//! the address the web client and the mpv gate use is the one this process bound.

use std::path::Path;
use std::sync::Mutex;

use once_cell::sync::Lazy;
use serde::Serialize;
use vortx_streaming_server::{start_server, ServerConfig, ServerHandle};

/// The server's lifecycle as reported to the web client (`server_status`).
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum ServerState {
    Running,
    Failed { reason: String },
    Disabled,
}

struct Running {
    handle: ServerHandle,
    base_url: String,
}

static SERVER: Lazy<Mutex<Option<Running>>> = Lazy::new(Default::default);
static STATE: Lazy<Mutex<ServerState>> = Lazy::new(|| Mutex::new(ServerState::Disabled));

fn set_state(state: ServerState) {
    *STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = state;
}

/// Start the server with its data (settings, piece cache, port file) under `data_dir`. Idempotent.
pub fn start(data_dir: &Path) {
    let mut server = SERVER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if server.is_some() {
        return;
    }
    if let Err(error) = std::fs::create_dir_all(data_dir) {
        set_state(ServerState::Failed {
            reason: format!("server data directory unavailable: {error}"),
        });
        return;
    }
    let config = ServerConfig {
        server_home: data_dir.to_path_buf(),
        port: 0,
        bind: "127.0.0.1".into(),
        lan_ip: None,
        port_file: Some(data_dir.join("server.port")),
        proxy_insecure_tls: false,
        proxy_allow_loopback: false,
        cache_size: None,
        bt_max_connections: None,
    };
    match start_server(config) {
        Ok(handle) => {
            let base_url = format!("http://127.0.0.1:{}", handle.port());
            *server = Some(Running { handle, base_url });
            set_state(ServerState::Running);
        }
        Err(error) => set_state(ServerState::Failed {
            reason: format!("streaming server failed to start: {error:#}"),
        }),
    }
}

/// The loopback base URL (`http://127.0.0.1:<port>`), or None while the server is not running.
pub fn base_url() -> Option<String> {
    SERVER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .as_ref()
        .map(|running| running.base_url.clone())
}

/// The bound `127.0.0.1:<port>` authority, for the mpv torrent gate.
pub fn authority() -> Option<String> {
    base_url().and_then(|base| base.strip_prefix("http://").map(str::to_owned))
}

pub fn status() -> ServerState {
    STATE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Stop the server and free its port. Idempotent.
pub fn stop() {
    let running = SERVER
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .take();
    if let Some(mut running) = running {
        running.handle.stop();
        set_state(ServerState::Disabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serves_on_an_ephemeral_loopback_port_and_stops_cleanly() {
        let dir = std::env::temp_dir().join(format!("vortx-desktop-server-{}", std::process::id()));
        start(&dir);
        assert_eq!(status(), ServerState::Running);
        let base = base_url().expect("running server has a base url");
        let port: u16 = base
            .strip_prefix("http://127.0.0.1:")
            .expect("loopback base")
            .parse()
            .expect("numeric port");
        assert_ne!(port, 0);
        assert_eq!(authority().as_deref(), Some(&base["http://".len()..]));
        // A second start is a no-op on the same server.
        start(&dir);
        assert_eq!(base_url().as_deref(), Some(base.as_str()));
        stop();
        assert_eq!(status(), ServerState::Disabled);
        assert!(base_url().is_none());
        std::fs::remove_dir_all(&dir).ok();
    }
}
