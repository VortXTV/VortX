//! The axum HTTP layer over the backend seam: the exact route set the app
//! calls (contract/GOLDEN.md), nothing more. No /yt, no DELETE routes.

pub mod files;
pub mod proxy;
pub mod settings;
pub mod torrents;

use std::sync::Arc;

use axum::routing::{any, get, post};
use axum::Router;

use crate::backend::TorrentBackend;
use crate::settings::SettingsStore;

pub struct ProxyState {
    pub client: reqwest::Client,
    /// Loopback destinations are refused unless a test flips this on.
    pub allow_loopback: bool,
}

pub struct AppState {
    pub backend: Arc<dyn TorrentBackend>,
    pub settings: Arc<SettingsStore>,
    pub proxy: ProxyState,
    /// The GET /settings `baseUrl` value (server.js: the LAN base).
    pub base_url: String,
}

/// The /proxy upstream client. Verifies TLS by default; `insecure_tls`
/// restores server.js's lax `rejectUnauthorized:false` for deployments that
/// need a broken-chain CDN (opt-in via VORTX_PROXY_INSECURE_TLS=1).
pub fn build_proxy_client(insecure_tls: bool) -> reqwest::Client {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none()) // manual, h= re-applied per hop
        .danger_accept_invalid_certs(insecure_tls)
        .connect_timeout(std::time::Duration::from_secs(15))
        .build()
        .expect("proxy client")
}

pub fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/settings", get(settings::get_settings).post(settings::post_settings))
        .route("/proxy/{*rest}", any(proxy::proxy))
        .route("/{info_hash}/create", post(torrents::create))
        .route("/{info_hash}/stats.json", get(torrents::stats))
        .route("/{info_hash}/remove", get(torrents::remove))
        .route("/{info_hash}/{file_idx}", get(files::file))
        .route("/{info_hash}", get(files::file_default))
        .with_state(state)
}
