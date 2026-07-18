//! The vortx-streaming-server bin: bind 127.0.0.1:11470 deterministically,
//! write the stremio-server.port file, serve the captured contract over the
//! rqbit backend, clean up on SIGTERM/ctrl-c.
//!
//! Environment:
//! - VORTX_SERVER_HOME  data root (settings.json, cache/)   [default ./vortx-streaming-server-data]
//! - VORTX_SERVER_PORT  port                                 [default 11470]
//! - VORTX_BIND         bind host (0.0.0.0 for LAN sharing)  [default 127.0.0.1]
//! - VORTX_PORT_FILE    port-file path                       [default {home}/stremio-server.port]
//! - VORTX_LAN_IP       advertised /settings baseUrl host    [default the bind/loopback host]
//! - VORTX_PROXY_INSECURE_TLS=1  server.js-parity lax TLS on /proxy (default OFF: verify)
//! - VORTX_PROXY_ALLOW_LOOPBACK=1  dev-only: let /proxy reach loopback origins

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Context;
use vortx_streaming_server::rqbit::RqbitBackend;
use vortx_streaming_server::settings::SettingsStore;
use vortx_streaming_server::{build_proxy_client, build_router, write_port_file, AppState, ProxyState};

fn env_flag(name: &str) -> bool {
    matches!(std::env::var(name).ok().as_deref(), Some("1") | Some("true") | Some("yes"))
}

/// Bind the configured port DETERMINISTICALLY: a bounded retry rides out a
/// fast-relaunch race (the old instance still releasing the port), then we
/// exit nonzero instead of silently drifting to 11471+ the way server.js did
/// (a drifted port used to strand whole sessions Offline).
async fn bind_deterministic(addr: SocketAddr) -> anyhow::Result<tokio::net::TcpListener> {
    let mut last_err = None;
    for attempt in 0..20 {
        match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => return Ok(l),
            Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
                if attempt == 0 {
                    tracing::warn!("{addr} in use; retrying up to 5s for the old instance to exit");
                }
                last_err = Some(e);
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            Err(e) => return Err(e).context("bind"),
        }
    }
    Err(last_err.map(anyhow::Error::from).unwrap_or_else(|| anyhow::anyhow!("bind failed")))
        .with_context(|| format!("{addr} stayed busy; refusing to drift ports"))
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,librqbit=warn".into()),
        )
        .init();

    let home = PathBuf::from(
        std::env::var("VORTX_SERVER_HOME")
            .unwrap_or_else(|_| "./vortx-streaming-server-data".into()),
    );
    std::fs::create_dir_all(&home).context("create server home")?;
    let port: u16 = std::env::var("VORTX_SERVER_PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(11470);
    let bind_host = std::env::var("VORTX_BIND").unwrap_or_else(|_| "127.0.0.1".into());
    let port_file = std::env::var("VORTX_PORT_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home.join("stremio-server.port"));

    let settings = Arc::new(SettingsStore::load(&home));
    let backend = RqbitBackend::new(home.join("stremio-cache"), settings.clone())
        .await
        .context("rqbit backend")?;

    let base_host = std::env::var("VORTX_LAN_IP").unwrap_or_else(|_| {
        if bind_host == "0.0.0.0" { "127.0.0.1".into() } else { bind_host.clone() }
    });
    let state = Arc::new(AppState {
        backend,
        settings,
        proxy: ProxyState {
            client: build_proxy_client(env_flag("VORTX_PROXY_INSECURE_TLS")),
            allow_loopback: env_flag("VORTX_PROXY_ALLOW_LOOPBACK"),
        },
        base_url: format!("http://{base_host}:{port}"),
    });

    let addr: SocketAddr = format!("{bind_host}:{port}").parse().context("bind address")?;
    let listener = bind_deterministic(addr).await?;
    write_port_file(&port_file, port).context("write port file")?;
    tracing::info!("EngineFS server started at http://{addr}"); // the line log-watchers key on

    let router = build_router(state);
    let port_file_cleanup = port_file.clone();
    axum::serve(listener, router)
        .with_graceful_shutdown(async move {
            let ctrl_c = tokio::signal::ctrl_c();
            #[cfg(unix)]
            {
                let mut term =
                    tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                        .expect("SIGTERM handler");
                tokio::select! {
                    _ = ctrl_c => {},
                    _ = term.recv() => {},
                }
            }
            #[cfg(not(unix))]
            {
                let _ = ctrl_c.await;
            }
        })
        .await
        .context("serve")?;

    std::fs::remove_file(&port_file_cleanup).ok();
    tracing::info!("streaming server stopped");
    Ok(())
}
