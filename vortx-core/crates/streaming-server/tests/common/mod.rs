//! Shared test plumbing: spawn the real axum app on an ephemeral loopback
//! port over a chosen backend, and load the checked-in golden.
//!
//! Not every test binary uses every helper; that's fine for a shared module.
#![allow(dead_code)]

use std::sync::Arc;

use vortx_streaming_server::backend::TorrentBackend;
use vortx_streaming_server::settings::SettingsStore;
use vortx_streaming_server::{build_proxy_client, build_router, AppState, ProxyState};

pub async fn spawn_app(backend: Arc<dyn TorrentBackend>, allow_loopback: bool) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let state = Arc::new(AppState {
        backend,
        settings: Arc::new(SettingsStore::in_memory("/tmp/vortx-ss-test")),
        proxy: ProxyState { client: build_proxy_client(false), allow_loopback },
        base_url: format!("http://{addr}"),
    });
    let router = build_router(state);
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    format!("http://{addr}")
}

pub fn golden() -> serde_json::Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/contract/stats-fields.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

pub fn golden_keys(golden: &serde_json::Value, field: &str) -> Vec<String> {
    golden[field]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}
