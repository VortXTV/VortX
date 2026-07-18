//! GET/HEAD /{infoHash}/{fileIdx}: the Range-capable playback endpoint.
//! Auto-creates the engine on a bare GET (CW resume), BLOCKS until the first
//! requested bytes are downloaded, and streams. Captured headers in
//! contract/GOLDEN.md section 4.

use std::io::SeekFrom;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, Method, StatusCode};
use axum::response::{IntoResponse, Response};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio_util::io::ReaderStream;

use super::AppState;
use crate::backend::{valid_info_hash, BackendError};
use crate::contract::content_type_for;
use crate::range::{parse_range, RangeOutcome};

const STREAM_CHUNK: usize = 64 * 1024;

/// `/{infoHash}` with no index: fileIdx defaults to 0.
pub async fn file_default(
    state: State<Arc<AppState>>,
    Path(info_hash): Path<String>,
    method: Method,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    serve(state, info_hash, 0, method, headers, uri).await
}

pub async fn file(
    state: State<Arc<AppState>>,
    Path((info_hash, file_idx)): Path<(String, String)>,
    method: Method,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    let Ok(idx) = file_idx.parse::<usize>() else {
        return StatusCode::NOT_FOUND.into_response();
    };
    serve(state, info_hash, idx, method, headers, uri).await
}

/// Repeated `?tr=` query trackers (stremio stream URLs carry them); they seed
/// the auto-create source list.
fn tr_sources(uri: &axum::http::Uri) -> Vec<String> {
    let Some(q) = uri.query() else { return Vec::new() };
    url::form_urlencoded::parse(q.as_bytes())
        .filter(|(k, _)| k == "tr")
        .map(|(_, v)| format!("tracker:{v}"))
        .collect()
}

async fn serve(
    State(state): State<Arc<AppState>>,
    info_hash: String,
    file_idx: usize,
    method: Method,
    headers: HeaderMap,
    uri: axum::http::Uri,
) -> Response {
    let hash = info_hash.to_ascii_lowercase();
    if !valid_info_hash(&hash) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let extra = tr_sources(&uri);
    let opened = match state.backend.open_file(&hash, file_idx, &extra).await {
        Ok(o) => o,
        Err(BackendError::UnknownTorrent) | Err(BackendError::BadFileIndex) => {
            return StatusCode::NOT_FOUND.into_response();
        }
        Err(e) => {
            tracing::warn!("open {hash}/{file_idx}: {e:#}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let total = opened.len;
    let content_type = content_type_for(&opened.file_name);

    let range_header = headers
        .get(header::RANGE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);

    let (status, start, end) = match parse_range(range_header.as_deref(), total) {
        RangeOutcome::Full => (StatusCode::OK, 0, total.saturating_sub(1)),
        RangeOutcome::Window { start, end } => (StatusCode::PARTIAL_CONTENT, start, end),
        RangeOutcome::Unsatisfiable => {
            let mut resp = StatusCode::RANGE_NOT_SATISFIABLE.into_response();
            if let Ok(v) = HeaderValue::from_str(&format!("bytes */{total}")) {
                resp.headers_mut().insert(header::CONTENT_RANGE, v);
            }
            return resp;
        }
    };
    let count = if total == 0 { 0 } else { end - start + 1 };

    let mut builder = Response::builder()
        .status(status)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::CONTENT_TYPE, content_type)
        .header(header::CACHE_CONTROL, "max-age=0, no-cache")
        .header(header::CONTENT_LENGTH, count);
    if status == StatusCode::PARTIAL_CONTENT {
        builder = builder.header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        );
    }

    if method == Method::HEAD {
        return builder.body(Body::empty()).unwrap_or_else(|_| {
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        });
    }

    let mut reader = opened.reader;
    if start > 0 {
        if let Err(e) = reader.seek(SeekFrom::Start(start)).await {
            tracing::warn!("seek {hash}/{file_idx}@{start}: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    let body = Body::from_stream(ReaderStream::with_capacity(reader.take(count), STREAM_CHUNK));
    builder
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}
