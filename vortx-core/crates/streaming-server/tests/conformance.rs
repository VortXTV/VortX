//! HTTP-contract conformance against the checked-in golden
//! (contract/stats-fields.json), over the hermetic stub backend. Field names
//! asserted byte-exact; Range/blocking semantics exercised for real over TCP.

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::{golden, golden_keys, spawn_app};
use vortx_streaming_server::stub::StubBackend;

const HASH: &str = "08ada5a7a6183aae1e09d831df6748d566095a10";

fn media_bytes() -> Vec<u8> {
    (0..=255u8).cycle().take(1_048_576).collect()
}

async fn app_with_media(ready: bool) -> (String, tokio::sync::watch::Sender<bool>) {
    let backend = Arc::new(StubBackend::new());
    let tx = backend.insert_torrent(
        HASH,
        "Sintel",
        vec![
            ("Sintel.en.srt".into(), b"1\n00:00:01,000 --> 00:00:02,000\nHi\n".to_vec()),
            ("Sintel.mp4".into(), media_bytes()),
        ],
        ready,
    );
    (spawn_app(backend, false).await, tx)
}

#[tokio::test]
async fn settings_get_has_the_values_object_and_every_golden_key() {
    let (base, _tx) = app_with_media(true).await;
    let resp = reqwest::get(format!("{base}/settings")).await.unwrap();
    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    let g = golden();
    for key in golden_keys(&g, "settings_top_level_keys") {
        assert!(body.get(&key).is_some(), "missing settings top-level key {key}");
    }
    let values = body["values"].as_object().expect("top-level values object");
    for key in golden_keys(&g, "settings_values_keys") {
        assert!(values.contains_key(&key), "missing values key {key}");
    }
}

#[tokio::test]
async fn settings_post_merges_and_reads_back() {
    let (base, _tx) = app_with_media(true).await;
    let client = reqwest::Client::new();
    let resp = client
        .post(format!("{base}/settings"))
        .header("content-type", "application/json")
        .body(r#"{"cacheSize":536870912,"btMaxConnections":24}"#)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    let body: serde_json::Value = resp.json().await.unwrap();
    assert_eq!(body, serde_json::json!({"success": true}), "captured POST body");

    let after: serde_json::Value = reqwest::get(format!("{base}/settings"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(after["values"]["cacheSize"], serde_json::json!(536870912));
    assert_eq!(after["values"]["btMaxConnections"], serde_json::json!(24));
}

#[tokio::test]
async fn create_is_idempotent_and_stats_keys_byte_match_the_golden() {
    let (base, _tx) = app_with_media(true).await;
    let client = reqwest::Client::new();
    let create_body = format!(
        r#"{{"torrent":{{"infoHash":"{HASH}"}},"peerSearch":{{"sources":["dht:{HASH}","tracker:http://tracker.opentrackr.org:1337/announce"],"min":40,"max":150}}}}"#
    );
    let g = golden();
    let expected: std::collections::BTreeSet<String> =
        golden_keys(&g, "stats_top_level_keys").into_iter().collect();

    for round in 0..2 {
        let resp = client
            .post(format!("{base}/{HASH}/create"))
            .header("content-type", "application/json")
            .body(create_body.clone())
            .send()
            .await
            .unwrap();
        assert_eq!(resp.status(), 200, "create round {round}");
        let body: serde_json::Value = resp.json().await.unwrap();
        let keys: std::collections::BTreeSet<String> =
            body.as_object().unwrap().keys().cloned().collect();
        assert_eq!(keys, expected, "create round {round} key set != golden");
        let files = body["files"].as_array().unwrap();
        assert!(!files.is_empty());
        for f in files {
            for key in golden_keys(&g, "file_entry_keys") {
                assert!(f.get(&key).is_some(), "files[] missing {key}");
            }
        }
    }

    // stats.json: same golden key set, and the six app-required fields typed.
    let stats: serde_json::Value = reqwest::get(format!("{base}/{HASH}/stats.json"))
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let keys: std::collections::BTreeSet<String> =
        stats.as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, expected, "stats.json key set != golden");
    for key in golden_keys(&g, "app_required_stats_keys") {
        assert!(stats.get(&key).is_some(), "app-required stats key {key}");
    }
    assert!(stats["peers"].is_u64());
    assert!(stats["swarmConnections"].is_u64());
    assert!(stats["downloaded"].is_number());
    assert!(stats["downloadSpeed"].is_number());
    assert!(stats["peerSearchRunning"].is_boolean());
}

#[tokio::test]
async fn unknown_hash_stats_is_200_null() {
    let (base, _tx) = app_with_media(true).await;
    let resp = reqwest::get(format!(
        "{base}/ffffffffffffffffffffffffffffffffffffffff/stats.json"
    ))
    .await
    .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        resp.headers().get("content-type").unwrap().to_str().unwrap(),
        "application/json"
    );
    assert_eq!(resp.text().await.unwrap(), "null", "captured null body");
}

#[tokio::test]
async fn remove_returns_200_empty_object_and_stats_goes_null() {
    let (base, _tx) = app_with_media(true).await;
    let client = reqwest::Client::new();
    client
        .post(format!("{base}/{HASH}/create"))
        .header("content-type", "application/json")
        .body(format!(r#"{{"torrent":{{"infoHash":"{HASH}"}}}}"#))
        .send()
        .await
        .unwrap();
    let resp = reqwest::get(format!("{base}/{HASH}/remove")).await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.text().await.unwrap(), "{}", "captured remove body");
    let stats = reqwest::get(format!("{base}/{HASH}/stats.json")).await.unwrap();
    assert_eq!(stats.text().await.unwrap(), "null");
}

#[tokio::test]
async fn file_endpoint_serves_ranges_like_the_capture() {
    let (base, _tx) = app_with_media(true).await;
    let media = media_bytes();
    let client = reqwest::Client::new();

    // Range window -> 206 + Content-Range + exact bytes (file idx 1 = the mp4).
    let resp = client
        .get(format!("{base}/{HASH}/1"))
        .header("Range", "bytes=100-199")
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 206);
    assert_eq!(
        resp.headers().get("content-range").unwrap().to_str().unwrap(),
        format!("bytes 100-199/{}", media.len())
    );
    assert_eq!(resp.headers().get("accept-ranges").unwrap(), "bytes");
    assert_eq!(resp.headers().get("content-type").unwrap(), "video/mp4");
    assert_eq!(resp.headers().get("content-length").unwrap(), "100");
    assert_eq!(resp.bytes().await.unwrap().as_ref(), &media[100..200]);

    // Suffix range.
    let resp = client
        .get(format!("{base}/{HASH}/1"))
        .header("Range", "bytes=-16")
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 206);
    assert_eq!(resp.bytes().await.unwrap().as_ref(), &media[media.len() - 16..]);

    // No Range -> 200 full length.
    let resp = client.get(format!("{base}/{HASH}/1")).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        resp.headers().get("content-length").unwrap().to_str().unwrap(),
        media.len().to_string()
    );

    // HEAD -> headers only.
    let resp = client.head(format!("{base}/{HASH}/1")).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(
        resp.headers().get("content-length").unwrap().to_str().unwrap(),
        media.len().to_string()
    );
    assert!(resp.bytes().await.unwrap().is_empty());

    // Unsatisfiable -> 416 bytes */len.
    let resp = client
        .get(format!("{base}/{HASH}/1"))
        .header("Range", format!("bytes={}-", media.len()))
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 416);
    assert_eq!(
        resp.headers().get("content-range").unwrap().to_str().unwrap(),
        format!("bytes */{}", media.len())
    );

    // Out-of-range file index -> 404; bad hash -> 404.
    assert_eq!(client.get(format!("{base}/{HASH}/9")).send().await.unwrap().status(), 404);
    assert_eq!(client.get(format!("{base}/nothex/0")).send().await.unwrap().status(), 404);
}

#[tokio::test]
async fn file_endpoint_blocks_until_pieces_are_ready() {
    let (base, ready_tx) = app_with_media(false).await; // gate closed
    let media = media_bytes();
    let client = reqwest::Client::new();
    let url = format!("{base}/{HASH}/1");

    let fetch = tokio::spawn(async move {
        client
            .get(url)
            .header("Range", "bytes=0-31")
            .send()
            .await
            .unwrap()
            .bytes()
            .await
            .unwrap()
    });

    // While the gate is closed, no bytes may complete.
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert!(!fetch.is_finished(), "body completed before pieces were ready");

    // Open the gate: the blocked read drains immediately.
    ready_tx.send(true).unwrap();
    let bytes = tokio::time::timeout(Duration::from_secs(5), fetch)
        .await
        .expect("unblocked after ready")
        .unwrap();
    assert_eq!(bytes.as_ref(), &media[..32]);
}

#[tokio::test]
async fn bare_file_get_auto_creates_the_engine() {
    // No prior /create: the CW-resume path. The GET must succeed AND flip the
    // engine on (stats stops being null).
    let (base, _tx) = app_with_media(true).await;
    let resp = reqwest::get(format!("{base}/{HASH}/0")).await.unwrap();
    assert_eq!(resp.status(), 200);
    let stats = reqwest::get(format!("{base}/{HASH}/stats.json")).await.unwrap();
    assert_ne!(stats.text().await.unwrap(), "null", "auto-create should open the engine");
}
