//! POST /{hash}/create, GET /{hash}/stats.json, GET /{hash}/remove.

use std::sync::Arc;
use std::time::Duration;

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use serde_json::{json, Value};

use super::AppState;
use crate::backend::{valid_info_hash, BackendError};
use crate::contract::EngineStats;

/// The app allows 75 s for a create (OpenLinkView); we cap just under it so a
/// metadata-less swarm surfaces an error instead of a client-side timeout.
const CREATE_TIMEOUT: Duration = Duration::from_secs(70);

/// Pull the peerSearch source list out of the create body:
/// `{"torrent":{"infoHash":..},"peerSearch":{"sources":[..],"min":40,"max":150}}`.
fn body_sources(body: &[u8]) -> Vec<String> {
    serde_json::from_slice::<Value>(body)
        .ok()
        .and_then(|v| {
            v.get("peerSearch")?.get("sources")?.as_array().map(|a| {
                a.iter()
                    .filter_map(|s| s.as_str().map(str::to_string))
                    .collect()
            })
        })
        .unwrap_or_default()
}

pub async fn create(
    State(state): State<Arc<AppState>>,
    Path(info_hash): Path<String>,
    body: Bytes,
) -> Response {
    let hash = info_hash.to_ascii_lowercase();
    if !valid_info_hash(&hash) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "err": "invalid infoHash" }))).into_response();
    }
    let sources = body_sources(&body);
    match tokio::time::timeout(CREATE_TIMEOUT, state.backend.create(&hash, &sources)).await {
        Ok(Ok(stats)) => Json(stats).into_response(),
        Ok(Err(BackendError::UnknownTorrent)) => {
            (StatusCode::NOT_FOUND, Json(json!({ "err": "unknown torrent" }))).into_response()
        }
        Ok(Err(e)) => {
            tracing::warn!("create {hash}: {e:#}");
            (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({ "err": e.to_string() }))).into_response()
        }
        Err(_) => (
            StatusCode::GATEWAY_TIMEOUT,
            Json(json!({ "err": "torrent metadata was not resolved in time" })),
        )
            .into_response(),
    }
}

/// Captured: an unknown/removed hash answers 200 `null` (application/json),
/// NOT a 404; the app's decoder fails soft and keeps polling.
pub async fn stats(State(state): State<Arc<AppState>>, Path(info_hash): Path<String>) -> Response {
    let hash = info_hash.to_ascii_lowercase();
    Json(state.backend.stats(&hash).await as Option<EngineStats>).into_response()
}

/// Captured: 200 `{}`. A GET by contract (the app's teardown call); no DELETE
/// route exists on this server.
pub async fn remove(State(state): State<Arc<AppState>>, Path(info_hash): Path<String>) -> Response {
    let hash = info_hash.to_ascii_lowercase();
    let _ = state.backend.remove(&hash).await;
    Json(json!({})).into_response()
}
