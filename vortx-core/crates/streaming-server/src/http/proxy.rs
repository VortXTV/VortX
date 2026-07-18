//! /proxy/d={originEnc}&h={Name:Value}.../{path}?{query}: the header
//! forwarder + HLS rewriter, transcribed from the server.js proxy module
//! (contract/GOLDEN.md section 7). Never proxies loopback destinations.

use std::net::IpAddr;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::{Request, State};
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use url::Url;

use super::AppState;
use crate::hls::{is_playlist, parse_opts, rewrite_playlist, ProxyOpts};

/// The request headers server.js forwards from the player to the origin.
/// (`connection`/`transfer-encoding` are hop-by-hop and managed by the HTTP
/// stack; `accept-encoding` is withheld so bodies pass through identity.)
const REQ_FORWARD: &[header::HeaderName] = &[
    header::ACCEPT,
    header::ACCEPT_LANGUAGE,
    header::RANGE,
    header::IF_RANGE,
    header::USER_AGENT,
];

/// The response headers server.js forwards from the origin to the player.
const RESP_FORWARD: &[header::HeaderName] = &[
    header::ACCEPT_RANGES,
    header::CONTENT_TYPE,
    header::CONTENT_LENGTH,
    header::CONTENT_RANGE,
    header::LAST_MODIFIED,
    header::ETAG,
    header::SERVER,
    header::DATE,
];

const MAX_REDIRECTS: usize = 5;

fn is_loopback_host(host: &str) -> bool {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if bare.eq_ignore_ascii_case("localhost") || bare == "0.0.0.0" {
        return true;
    }
    bare.parse::<IpAddr>().map(|ip| ip.is_loopback()).unwrap_or(false)
}

/// Build the upstream request headers: the client whitelist, then the h=
/// headers on top (server.js order).
fn upstream_headers(client: &HeaderMap, opts: &ProxyOpts) -> HeaderMap {
    let mut out = HeaderMap::new();
    for name in REQ_FORWARD {
        if let Some(v) = client.get(name) {
            out.insert(name.clone(), v.clone());
        }
    }
    for (name, value) in &opts.headers {
        if let (Ok(n), Ok(v)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            out.insert(n, v);
        }
    }
    out
}

pub async fn proxy(State(state): State<Arc<AppState>>, req: Request) -> Response {
    // Parse from the RAW uri: the opts segment holds percent-encoded '/' that
    // a decoded Path extractor would corrupt.
    let path = req.uri().path().to_string();
    let query = req.uri().query().map(str::to_string);
    let Some(rest) = path.strip_prefix("/proxy/") else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let (raw_opts, upstream_path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    let opts = parse_opts(raw_opts);

    let Some(dest_origin) = opts.destination.as_deref() else {
        return (StatusCode::BAD_REQUEST, "missing d= destination").into_response();
    };
    let Ok(origin_url) = Url::parse(dest_origin) else {
        return (StatusCode::BAD_REQUEST, "invalid d= destination").into_response();
    };
    if !matches!(origin_url.scheme(), "http" | "https") {
        return (StatusCode::BAD_REQUEST, "unsupported destination scheme").into_response();
    }
    let host = origin_url.host_str().unwrap_or_default().to_string();
    if host.is_empty() {
        return (StatusCode::BAD_REQUEST, "invalid d= destination").into_response();
    }
    if !state.proxy.allow_loopback && is_loopback_host(&host) {
        return (StatusCode::FORBIDDEN, "loopback destinations are not proxied").into_response();
    }

    // Splice origin + raw (still-encoded) path + query.
    let dest_str = format!(
        "{}{}{}",
        dest_origin.trim_end_matches('/'),
        upstream_path,
        query.as_deref().map(|q| format!("?{q}")).unwrap_or_default()
    );
    let Ok(mut dest) = Url::parse(&dest_str) else {
        return (StatusCode::BAD_REQUEST, "invalid destination url").into_response();
    };

    let method = match reqwest::Method::from_bytes(req.method().as_str().as_bytes()) {
        Ok(m) => m,
        Err(_) => return StatusCode::METHOD_NOT_ALLOWED.into_response(),
    };
    let client_headers = req.headers().clone();

    // Manual redirect loop, h= re-applied per hop (server.js parity).
    let mut upstream = None;
    for _hop in 0..=MAX_REDIRECTS {
        let request = state
            .proxy
            .client
            .request(method.clone(), dest.clone())
            .headers(upstream_headers(&client_headers, &opts));
        let resp = match request.send().await {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("proxy fetch {dest}: {e}");
                return (StatusCode::BAD_GATEWAY, "upstream fetch failed").into_response();
            }
        };
        if resp.status().is_redirection() {
            if let Some(loc) = resp
                .headers()
                .get(header::LOCATION)
                .and_then(|v| v.to_str().ok())
            {
                match dest.join(loc) {
                    Ok(next) => {
                        let next_host = next.host_str().unwrap_or_default().to_string();
                        if !state.proxy.allow_loopback && is_loopback_host(&next_host) {
                            return (StatusCode::FORBIDDEN, "loopback redirect refused")
                                .into_response();
                        }
                        dest = next;
                        continue;
                    }
                    Err(_) => {
                        return (StatusCode::BAD_GATEWAY, "bad redirect location").into_response()
                    }
                }
            }
        }
        upstream = Some(resp);
        break;
    }
    let Some(upstream) = upstream else {
        return (StatusCode::BAD_GATEWAY, "too many redirects").into_response();
    };

    let status =
        StatusCode::from_u16(upstream.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let mut headers = HeaderMap::new();
    for name in RESP_FORWARD {
        if let Some(v) = upstream.headers().get(name) {
            headers.insert(name.clone(), v.clone());
        }
    }
    for (name, value) in &opts.response_headers {
        if let (Ok(n), Ok(v)) = (
            HeaderName::from_bytes(name.as_bytes()),
            HeaderValue::from_str(value),
        ) {
            headers.insert(n, v);
        }
    }

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    let playlist = is_playlist(dest.path(), content_type.as_deref());

    if playlist {
        // Buffer + rewrite. Content-Length is recomputed by hyper for the
        // rewritten body; ranges make no sense on a rewritten playlist.
        headers.remove(header::CONTENT_LENGTH);
        headers.insert(header::ACCEPT_RANGES, HeaderValue::from_static("none"));
        let body = match upstream.text().await {
            Ok(t) => t,
            Err(e) => {
                tracing::warn!("proxy playlist read {dest}: {e}");
                return (StatusCode::BAD_GATEWAY, "upstream body failed").into_response();
            }
        };
        let virtual_root = format!("/proxy/{raw_opts}");
        let rewritten = rewrite_playlist(&body, &virtual_root, &dest, &opts.raw_h);
        let mut resp = Response::builder()
            .status(status)
            .body(Body::from(rewritten))
            .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
        *resp.headers_mut() = headers;
        return resp;
    }

    // Non-playlist: stream bytes through untouched.
    let stream = upstream.bytes_stream();
    let mut resp = Response::builder()
        .status(status)
        .body(Body::from_stream(stream))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response());
    *resp.headers_mut() = headers;
    resp
}
