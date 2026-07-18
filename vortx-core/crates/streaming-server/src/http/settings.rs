//! GET /settings (the app's online-readiness signal: 200 + a top-level
//! `values` object) and POST /settings (merge, 200 {"success":true}).

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Json, Response};
use serde_json::{json, Map, Value};

use super::AppState;

/// The captured option descriptors (shape parity; no app call site reads them).
fn options() -> Value {
    json!([
        { "id": "localAddonEnabled", "label": "ENABLE_LOCAL_FILES_ADDON", "type": "checkbox" },
        { "id": "remoteHttps", "label": "ENABLE_REMOTE_HTTPS_CONN", "type": "select",
          "class": "https", "icon": true,
          "selections": [ { "name": "Disabled", "val": "" } ] },
        { "id": "cacheSize", "label": "CACHING", "type": "select", "class": "caching", "icon": true,
          "selections": [
            { "name": "no caching", "val": 0 },
            { "name": "2GB", "val": 2147483648u64 },
            { "name": "5GB", "val": 5368709120u64 },
            { "name": "10GB", "val": 10737418240u64 },
            { "name": "\u{221e}", "val": null }
          ] }
    ])
}

pub async fn get_settings(State(state): State<Arc<AppState>>) -> Response {
    let body = json!({
        "options": options(),
        "values": Value::Object(state.settings.values()),
        "baseUrl": state.base_url,
    });
    ([(axum::http::header::CACHE_CONTROL, "no-store")], Json(body)).into_response()
}

pub async fn post_settings(State(state): State<Arc<AppState>>, body: Bytes) -> Response {
    match serde_json::from_slice::<Value>(&body) {
        Ok(Value::Object(posted)) => {
            state.settings.merge(posted);
            Json(json!({ "success": true })).into_response()
        }
        // Tolerate an empty/no-op post the way server.js's extend does.
        Ok(_) | Err(_) if body.is_empty() => {
            state.settings.merge(Map::new());
            Json(json!({ "success": true })).into_response()
        }
        _ => (StatusCode::BAD_REQUEST, Json(json!({ "success": false }))).into_response(),
    }
}
