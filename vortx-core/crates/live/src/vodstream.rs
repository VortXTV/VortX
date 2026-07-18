//! LT-VOD: map IPTV VOD (M3U playlist entries + Xtream `get_vod_streams` JSON) onto the one
//! [`vortx_protocol::Stream`] shape, so an installed IPTV source's movies compete in the SAME ranked stream
//! list as a Stremio addon, a Nuvio provider, or a debrid result, with zero provider cooperation. This is the
//! IPTV twin of `vortx_adapters::scraper_streams_to_protocol`: pure data mapping, no fetch, no clock.
//!
//! The ranker reads the release title (name) for the resolution/HDR tier exactly as it does for any other
//! source, so a `Movie 2160p` M3U/Xtream entry ranks against a `Movie 1080p WEB-DL` torrent with no special
//! case. Each mapped stream is tagged with a typed `behaviorHints.vortx.kind = "http"` side-channel so the
//! engine routes it as a direct HTTP stream (an IPTV VOD is always a direct URL, never a torrent/NZB).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use vortx_protocol::{Stream, StreamBehaviorHints, VortxStreamHints};

use crate::m3u::{M3uEntry, Playlist};
use crate::xtream::XtreamPortal;

/// One VOD entry from an Xtream `get_vod_streams` response. Tolerant: `stream_id` arrives as a JSON number on
/// most portals and a string on some, so it is normalized to a string at the boundary; every other field is
/// optional. Parsed via [`parse_xtream_vod`] (which is liberal in what it accepts, Postel-style).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct XtreamVodStream {
    /// The portal's stream id (used to build the playable `/movie/{user}/{pass}/{id}.{ext}` URL).
    pub stream_id: String,
    /// The display/release name (carries the resolution token the ranker reads).
    pub name: String,
    /// Playable container extension (`mkv`/`mp4`/...); defaults to `mp4` when the portal omits it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub container_extension: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category_id: Option<String>,
}

/// Parse an Xtream `get_vod_streams` JSON body into VOD entries. Tolerant + panic-free: a non-array body yields
/// an empty list, and an entry without a `stream_id` (unplayable) is skipped. `stream_id` accepts number or
/// string; missing `name` degrades to empty (still playable by id).
pub fn parse_xtream_vod(json: &str) -> Vec<XtreamVodStream> {
    let values: Vec<Value> = serde_json::from_str(json).unwrap_or_default();
    values.iter().filter_map(vod_from_value).collect()
}

fn vod_from_value(v: &Value) -> Option<XtreamVodStream> {
    let stream_id = value_to_id(v.get("stream_id")?)?;
    Some(XtreamVodStream {
        stream_id,
        name: v.get("name").and_then(Value::as_str).unwrap_or_default().to_string(),
        container_extension: string_field(v, "container_extension"),
        stream_icon: string_field(v, "stream_icon"),
        rating: v.get("rating").and_then(value_to_id),
        category_id: v.get("category_id").and_then(value_to_id),
    })
}

/// Normalize a JSON scalar (number or non-empty string) to a string; `None` for null/empty/other.
fn value_to_id(v: &Value) -> Option<String> {
    match v {
        Value::String(s) if !s.is_empty() => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn string_field(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// Map one Xtream VOD entry to a protocol [`Stream`], building the playable URL from the portal (the creds are
/// encoded into the returned URL only, never logged). The container extension defaults to `mp4`.
pub fn xtream_vod_to_stream(portal: &XtreamPortal, vod: &XtreamVodStream) -> Stream {
    let ext = vod.container_extension.as_deref().unwrap_or("mp4");
    Stream {
        url: Some(portal.vod_url(&vod.stream_id, ext)),
        name: Some(vod.name.clone()),
        behavior_hints: Some(http_hints()),
        ..Default::default()
    }
}

/// Map a whole Xtream VOD list to protocol streams.
pub fn xtream_vod_to_streams(portal: &XtreamPortal, vods: &[XtreamVodStream]) -> Vec<Stream> {
    vods.iter().map(|v| xtream_vod_to_stream(portal, v)).collect()
}

/// Map one M3U playlist entry to a protocol [`Stream`]. The entry's URL is already playable (M3U carries the
/// direct URL), and any #EXTVLCOPT HTTP headers become `behaviorHints.proxyHeaders.request` so the player
/// injects them, exactly like a Nuvio provider's headers.
pub fn m3u_entry_to_stream(entry: &M3uEntry) -> Stream {
    let name = if entry.display_name.is_empty() {
        entry.tvg_name.clone().unwrap_or_default()
    } else {
        entry.display_name.clone()
    };
    Stream {
        url: Some(entry.url.clone()),
        name: Some(name),
        behavior_hints: Some(m3u_hints(entry)),
        ..Default::default()
    }
}

/// Map a whole M3U playlist's entries to protocol streams (its VOD movies competing in the ranked list).
pub fn m3u_vod_to_streams(playlist: &Playlist) -> Vec<Stream> {
    playlist.entries.iter().map(m3u_entry_to_stream).collect()
}

/// The typed side-channel marking a mapped IPTV stream as a direct HTTP source (never torrent/NZB).
fn http_hints() -> StreamBehaviorHints {
    StreamBehaviorHints {
        vortx: Some(VortxStreamHints {
            kind: Some("http".to_string()),
            ..Default::default()
        }),
        ..Default::default()
    }
}

/// Hints for an M3U entry: the HTTP source marker plus any per-entry injected headers as proxyHeaders.
fn m3u_hints(entry: &M3uEntry) -> StreamBehaviorHints {
    let mut hints = http_hints();
    if !entry.headers.is_empty() {
        let request: serde_json::Map<String, Value> = entry
            .headers
            .iter()
            .map(|(k, v)| (k.clone(), Value::from(v.clone())))
            .collect();
        hints.proxy_headers = Some(serde_json::json!({ "request": request }));
    }
    hints
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::m3u::parse_m3u;
    use crate::secret::Secret;

    #[test]
    fn m3u_entry_becomes_a_ranked_ready_protocol_stream() {
        let playlist = parse_m3u(
            "#EXTM3U\n#EXTINF:-1 tvg-name=\"The Movie 2160p\",The Movie 2160p\n\
             #EXTVLCOPT:http-user-agent=CustomUA\nhttp://vod.example/movie/9000.mkv\n",
        );
        let streams = m3u_vod_to_streams(&playlist);
        assert_eq!(streams.len(), 1);
        let s = &streams[0];
        assert_eq!(s.url.as_deref(), Some("http://vod.example/movie/9000.mkv"));
        assert_eq!(s.name.as_deref(), Some("The Movie 2160p")); // resolution token the ranker reads
        let hints = s.behavior_hints.as_ref().unwrap();
        assert_eq!(hints.vortx.as_ref().unwrap().kind.as_deref(), Some("http"));
        // Injected header carried as proxyHeaders.request so the player can play a UA-gated CDN.
        assert_eq!(hints.proxy_headers.as_ref().unwrap()["request"]["User-Agent"], "CustomUA");
    }

    #[test]
    fn xtream_vod_json_maps_to_playable_streams() {
        // A get_vod_streams body: stream_id as a NUMBER (the common case), plus a string-id entry.
        let json = r#"[
            {"num":1,"name":"Movie A 1080p","stream_type":"movie","stream_id":12345,"container_extension":"mkv","category_id":3},
            {"num":2,"name":"Movie B 2160p","stream_id":"678","container_extension":"mp4"}
        ]"#;
        let vods = parse_xtream_vod(json);
        assert_eq!(vods.len(), 2);
        assert_eq!(vods[0].stream_id, "12345"); // number normalized to string
        assert_eq!(vods[1].stream_id, "678");
        let portal = XtreamPortal::new("http://host:8080", "alice", Secret::new("pw"));
        let streams = xtream_vod_to_streams(&portal, &vods);
        assert_eq!(streams.len(), 2);
        assert_eq!(streams[0].url.as_deref(), Some("http://host:8080/movie/alice/pw/12345.mkv"));
        assert_eq!(streams[0].name.as_deref(), Some("Movie A 1080p"));
        assert_eq!(streams[1].url.as_deref(), Some("http://host:8080/movie/alice/pw/678.mp4"));
        assert_eq!(
            streams[0].behavior_hints.as_ref().unwrap().vortx.as_ref().unwrap().kind.as_deref(),
            Some("http")
        );
    }

    #[test]
    fn missing_container_extension_defaults_to_mp4() {
        let vods = parse_xtream_vod(r#"[{"name":"X","stream_id":5}]"#);
        let portal = XtreamPortal::new("http://h", "u", Secret::new("p"));
        let s = xtream_vod_to_stream(&portal, &vods[0]);
        assert_eq!(s.url.as_deref(), Some("http://h/movie/u/p/5.mp4"));
    }

    #[test]
    fn tolerant_of_a_non_array_or_empty_body() {
        assert!(parse_xtream_vod("not json").is_empty());
        assert!(parse_xtream_vod("{}").is_empty());
        // An entry without a stream_id is unplayable and skipped.
        assert!(parse_xtream_vod(r#"[{"name":"no id"}]"#).is_empty());
    }
}
