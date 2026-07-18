//! LIVE torrent proof over the real rqbit backend: creates the public-domain
//! Sintel torrent (the same hash the golden was captured with), waits for the
//! swarm, and range-reads real bytes off the file endpoint.
//!
//! `#[ignore]` by default: needs the network + a live swarm. Run with
//!   cargo test -p vortx-streaming-server --test live_rqbit -- --ignored --nocapture

mod common;

use std::sync::Arc;
use std::time::Duration;

use common::spawn_app;
use vortx_streaming_server::rqbit::RqbitBackend;
use vortx_streaming_server::settings::SettingsStore;

const SINTEL: &str = "08ada5a7a6183aae1e09d831df6748d566095a10";

#[tokio::test(flavor = "multi_thread")]
#[ignore = "network: needs a live swarm"]
async fn live_sintel_create_stats_and_range_read() {
    let home = std::env::temp_dir().join(format!("vortx-ss-live-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let settings = Arc::new(SettingsStore::load(&home));
    let backend = RqbitBackend::new(home.join("stremio-cache"), settings)
        .await
        .expect("rqbit session");
    let base = spawn_app(backend, false).await;

    // create (blocks until metadata): the app's exact body shape.
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .build()
        .unwrap();
    let body = format!(
        r#"{{"torrent":{{"infoHash":"{SINTEL}"}},"peerSearch":{{"sources":["dht:{SINTEL}","tracker:http://tracker.opentrackr.org:1337/announce","tracker:udp://tracker.opentrackr.org:1337/announce","tracker:https://tracker.bt4g.com:443/announce"],"min":40,"max":150}}}}"#
    );
    let resp = client
        .post(format!("{base}/{SINTEL}/create"))
        .header("content-type", "application/json")
        .body(body)
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 200, "create must 200 once metadata is in");
    let created: serde_json::Value = resp.json().await.unwrap();
    let files = created["files"].as_array().expect("files in create response");
    println!("create returned {} files, name={}", files.len(), created["name"]);
    let (mp4_idx, mp4) = files
        .iter()
        .enumerate()
        .find(|(_, f)| f["name"].as_str().unwrap_or("").ends_with(".mp4"))
        .expect("an mp4 in Sintel");
    let mp4_len = mp4["length"].as_u64().unwrap();

    // Range-read the head of the movie: BLOCKS until the swarm delivers.
    let resp = client
        .get(format!("{base}/{SINTEL}/{mp4_idx}"))
        .header("Range", "bytes=0-1023")
        .send()
        .await
        .unwrap();
    assert_eq!(resp.status(), 206);
    assert_eq!(
        resp.headers().get("content-range").unwrap().to_str().unwrap(),
        format!("bytes 0-1023/{mp4_len}")
    );
    let bytes = resp.bytes().await.unwrap();
    assert_eq!(bytes.len(), 1024);
    assert_eq!(&bytes[4..8], b"ftyp", "mp4 magic: real torrent bytes");
    println!("range read OK: 1024 bytes, ftyp magic present");

    // stats.json shows the live swarm.
    let stats: serde_json::Value = client
        .get(format!("{base}/{SINTEL}/stats.json"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    println!(
        "stats: peers={} swarmConnections={} downloaded={} downloadSpeed={}",
        stats["peers"], stats["swarmConnections"], stats["downloaded"], stats["downloadSpeed"]
    );
    assert!(stats["downloaded"].as_f64().unwrap() > 0.0, "bytes actually downloaded");

    // teardown parity
    let resp = client.get(format!("{base}/{SINTEL}/remove")).send().await.unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.text().await.unwrap(), "{}");
    std::fs::remove_dir_all(&home).ok();
}
