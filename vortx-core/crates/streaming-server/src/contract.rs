//! The serialized shapes of the server.js contract, field names BYTE-EXACT per
//! contract/GOLDEN.md. Struct field order mirrors the captured JSON order.
//! Do not rename, re-case, or reorder without re-capturing the golden.

use serde::Serialize;

/// One entry of the `files` array in the create/stats responses. Captured:
/// `{"path":"Sintel/Sintel.mp4","name":"Sintel.mp4","length":129241752,"offset":7884}`.
#[derive(Serialize, Clone, Debug)]
pub struct FileEntry {
    pub path: String,
    pub name: String,
    pub length: u64,
    pub offset: u64,
}

/// One entry of the `sources` array (the peer-search source echo). The app
/// never reads these; shape parity with the capture.
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SourceEntry {
    pub num_found: u64,
    pub num_found_uniq: u64,
    pub num_requests: u64,
    pub url: String,
    pub last_started: String,
}

/// The engine-status JSON served by BOTH `POST /{hash}/create` and
/// `GET /{hash}/stats.json` (captured: identical key sets). The app's hard
/// contract is the six fields its `TorrentStats` decoders read: `peers`,
/// `swarmConnections`, `connectionTries`, `peerSearchRunning`, `downloaded`,
/// `downloadSpeed`; plus `files[].name`/`files[].length` on the create
/// response (OpenLinkView magnet resolution). Everything else is shape parity.
#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct EngineStats {
    pub info_hash: String,
    pub name: String,
    pub peers: u64,
    pub unchoked: u64,
    pub queued: u64,
    pub unique: u64,
    pub connection_tries: u64,
    pub swarm_paused: bool,
    pub swarm_connections: u64,
    pub swarm_size: u64,
    pub selections: Vec<serde_json::Value>,
    pub wires: Vec<serde_json::Value>,
    pub files: Vec<FileEntry>,
    pub downloaded: u64,
    pub uploaded: u64,
    pub download_speed: f64,
    pub upload_speed: f64,
    pub sources: Vec<SourceEntry>,
    pub peer_search_running: bool,
    pub opts: serde_json::Value,
}

/// Build the `sources` echo from a peerSearch source list.
pub fn source_entries(sources: &[String]) -> Vec<SourceEntry> {
    let now = iso8601_now();
    sources
        .iter()
        .map(|url| SourceEntry {
            num_found: 0,
            num_found_uniq: 0,
            num_requests: 1,
            url: url.clone(),
            last_started: now.clone(),
        })
        .collect()
}

/// Current UTC time as `YYYY-MM-DDTHH:MM:SS.mmmZ` (the server.js `lastStarted`
/// shape) without pulling a chrono dependency. Cosmetic only: no call site
/// parses it.
pub fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs() as i64;
    let millis = now.subsec_millis();
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400);
    let (h, m, s) = (sod / 3600, (sod % 3600) / 60, sod % 60);
    // civil-from-days (Howard Hinnant's algorithm), valid for the era in use.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mth = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mth <= 2 { y + 1 } else { y };
    format!("{y:04}-{mth:02}-{d:02}T{h:02}:{m:02}:{s:02}.{millis:03}Z")
}

/// Content-Type by file extension. server.js uses a full mime lookup; these
/// cover the containers/sidecars torrents actually carry (video/mp4 is the
/// one live-captured value).
pub fn content_type_for(name: &str) -> &'static str {
    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "ts" | "m2ts" => "video/mp2t",
        "mpg" | "mpeg" => "video/mpeg",
        "wmv" => "video/x-ms-wmv",
        "mp3" => "audio/mpeg",
        "aac" => "audio/aac",
        "flac" => "audio/flac",
        "srt" => "application/x-subrip",
        "vtt" => "text/vtt",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stats_serializes_the_captured_field_names() {
        let stats = EngineStats {
            info_hash: "a".repeat(40),
            name: "T".into(),
            peers: 1,
            unchoked: 1,
            queued: 0,
            unique: 2,
            connection_tries: 3,
            swarm_paused: false,
            swarm_connections: 4,
            swarm_size: 5,
            selections: vec![],
            wires: vec![],
            files: vec![FileEntry { path: "T/a.mp4".into(), name: "a.mp4".into(), length: 9, offset: 0 }],
            downloaded: 0,
            uploaded: 0,
            download_speed: 0.0,
            upload_speed: 0.0,
            sources: source_entries(&["dht:x".into()]),
            peer_search_running: true,
            opts: serde_json::json!({}),
        };
        let v: serde_json::Value = serde_json::to_value(&stats).unwrap();
        for key in [
            "infoHash", "name", "peers", "unchoked", "queued", "unique",
            "connectionTries", "swarmPaused", "swarmConnections", "swarmSize",
            "selections", "wires", "files", "downloaded", "uploaded",
            "downloadSpeed", "uploadSpeed", "sources", "peerSearchRunning", "opts",
        ] {
            assert!(v.get(key).is_some(), "missing byte-exact key {key}");
        }
        let file = &v["files"][0];
        for key in ["path", "name", "length", "offset"] {
            assert!(file.get(key).is_some(), "missing files[] key {key}");
        }
        let src = &v["sources"][0];
        for key in ["numFound", "numFoundUniq", "numRequests", "url", "lastStarted"] {
            assert!(src.get(key).is_some(), "missing sources[] key {key}");
        }
    }

    #[test]
    fn iso8601_now_shape() {
        let s = iso8601_now();
        assert_eq!(s.len(), 24, "{s}");
        assert!(s.ends_with('Z') && s.contains('T'));
    }
}
