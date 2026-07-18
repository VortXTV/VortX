//! /proxy round-trip conformance: header forwarding (h= split on the FIRST
//! colon), the HLS rewrite rules, response-header whitelisting, and the
//! loopback guard. The origin is a local axum server; the app under test runs
//! with allow_loopback=true so the round-trip stays hermetic (the guard itself
//! is tested on a second instance with the default config).

mod common;

use std::sync::Arc;

use axum::http::HeaderMap;
use axum::response::IntoResponse;
use axum::routing::get;
use axum::Router;
use common::spawn_app;
use vortx_streaming_server::stub::StubBackend;

/// A local origin that echoes request headers and serves a crafted master
/// playlist whose entries cover every rewrite case.
async fn spawn_origin() -> (String, u16) {
    async fn echo(headers: HeaderMap) -> impl IntoResponse {
        let map: serde_json::Map<String, serde_json::Value> = headers
            .iter()
            .map(|(k, v)| {
                (k.as_str().to_string(), serde_json::json!(v.to_str().unwrap_or("")))
            })
            .collect();
        axum::Json(serde_json::Value::Object(map))
    }
    async fn playlist(axum::extract::State(port): axum::extract::State<u16>) -> impl IntoResponse {
        let body = format!(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nvariant/index.m3u8\n/root/abs.m3u8\nhttp://127.0.0.1:{port}/same/origin.m3u8?tok=1\nhttps://cdn.example.com/other/low.m3u8?x=2\n#EXT-X-KEY:METHOD=AES-128,URI=\"/keys/k1.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        );
        ([("content-type", "application/vnd.apple.mpegurl")], body)
    }
    async fn media() -> impl IntoResponse {
        (
            [("content-type", "application/octet-stream"), ("x-origin-secret", "leak-me-not")],
            vec![7u8; 64],
        )
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let router = Router::new()
        .route("/echo/headers", get(echo))
        .route("/hls/master.m3u8", get(playlist))
        .route("/media/file.bin", get(media))
        .with_state(port);
    tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    (format!("http://127.0.0.1:{port}"), port)
}

fn opts_segment(port: u16) -> String {
    // Exactly the shape StremioServer.proxiedURL builds: d= origin, repeated
    // h= "Name:Value", separators percent-encoded.
    format!(
        "d=http%3A%2F%2F127.0.0.1%3A{port}&h=Referer%3Ahttp%3A%2F%2Fok.ru%2Fpage%3Fq%3D1&h=User-Agent%3AVortXTest%2F1.0"
    )
}

#[tokio::test]
async fn forwards_h_headers_split_on_first_colon() {
    let (_origin, port) = spawn_origin().await;
    let backend = Arc::new(StubBackend::new());
    let base = spawn_app(backend, true).await;

    let url = format!("{base}/proxy/{}/echo/headers?a=1", opts_segment(port));
    let resp = reqwest::get(&url).await.unwrap();
    assert_eq!(resp.status(), 200);
    let seen: serde_json::Value = resp.json().await.unwrap();
    // First-colon split: the Referer value keeps its own colons + query.
    assert_eq!(seen["referer"], "http://ok.ru/page?q=1");
    assert_eq!(seen["user-agent"], "VortXTest/1.0");
}

#[tokio::test]
async fn rewrites_hls_master_per_the_captured_rules() {
    let (_origin, port) = spawn_origin().await;
    let backend = Arc::new(StubBackend::new());
    let base = spawn_app(backend, true).await;

    let seg = opts_segment(port);
    let vroot = format!("/proxy/{seg}");
    let resp = reqwest::get(format!("{base}/proxy/{seg}/hls/master.m3u8"))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.headers().get("accept-ranges").unwrap(), "none");
    assert_eq!(
        resp.headers().get("content-type").unwrap(),
        "application/vnd.apple.mpegurl"
    );
    let body = resp.text().await.unwrap();
    let lines: Vec<&str> = body.lines().collect();
    assert_eq!(lines[2], "variant/index.m3u8", "relative URIs stay untouched");
    assert_eq!(lines[3], format!("{vroot}/root/abs.m3u8"), "root-relative -> virtual root");
    assert_eq!(
        lines[4],
        format!("{vroot}/same/origin.m3u8?tok=1"),
        "same-origin absolute -> virtual root + path"
    );
    assert_eq!(
        lines[5],
        "/proxy/d=https%3A%2F%2Fcdn.example.com&h=Referer%3Ahttp%3A%2F%2Fok.ru%2Fpage%3Fq%3D1&h=User-Agent%3AVortXTest%2F1.0/other/low.m3u8?x=2",
        "different-origin absolute -> fresh /proxy root carrying the same h="
    );
    assert_eq!(
        lines[6],
        format!("#EXT-X-KEY:METHOD=AES-128,URI=\"{vroot}/keys/k1.bin\""),
        "URI= attributes rewritten inside tag lines"
    );
    assert_eq!(lines[7], "#EXT-X-MAP:URI=\"init.mp4\"", "relative URI= stays untouched");
}

#[tokio::test]
async fn streams_non_playlists_and_whitelists_response_headers() {
    let (_origin, port) = spawn_origin().await;
    let backend = Arc::new(StubBackend::new());
    let base = spawn_app(backend, true).await;

    let resp = reqwest::get(format!("{base}/proxy/{}/media/file.bin", opts_segment(port)))
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.headers().get("content-type").unwrap(), "application/octet-stream");
    // Non-whitelisted origin headers must NOT pass through (server.js parity).
    assert!(resp.headers().get("x-origin-secret").is_none());
    assert_eq!(resp.bytes().await.unwrap().as_ref(), &[7u8; 64][..]);
}

#[tokio::test]
async fn refuses_loopback_destinations_by_default() {
    let backend = Arc::new(StubBackend::new());
    let base = spawn_app(backend, false).await; // production config
    for origin_enc in [
        "http%3A%2F%2F127.0.0.1%3A9",
        "http%3A%2F%2Flocalhost%3A9",
        "http%3A%2F%2F127.8.4.4",
    ] {
        let resp = reqwest::get(format!("{base}/proxy/d={origin_enc}/x")).await.unwrap();
        assert_eq!(resp.status(), 403, "loopback origin {origin_enc} must be refused");
    }
}

#[tokio::test]
async fn rejects_missing_or_invalid_destinations() {
    let backend = Arc::new(StubBackend::new());
    let base = spawn_app(backend, true).await;
    let resp = reqwest::get(format!("{base}/proxy/h=X%3AY/path")).await.unwrap();
    assert_eq!(resp.status(), 400);
    let resp = reqwest::get(format!("{base}/proxy/d=ftp%3A%2F%2Fx.example/path"))
        .await
        .unwrap();
    assert_eq!(resp.status(), 400);
}
