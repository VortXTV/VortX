//! The CLI's output document: the host-facing JSON the proof asserts byte-stability over. Field
//! order is fixed by the struct definitions and every map is a `BTreeMap`, so serialization is a
//! pure function of the inputs; two runs over identical `(now, bodies, flags)` serialize to
//! byte-identical documents. No wall-clock, no paths, no environment leaks into this shape.

use serde::Serialize;
use vortx_debrid::{DebridService, ResolveSource, ResolveStep};
use vortx_protocol::Stream;
use vortx_ranking::{Audio, RankedStream, Tier};
use vortx_source::{cached_on, BreakerRegistry, FailedAddon, FetchRequest};

/// The whole resolve document printed to stdout.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveOutput {
    /// Output schema tag, so downstream tooling can gate on shape changes.
    pub schema: &'static str,
    pub meta: String,
    #[serde(rename = "type")]
    pub content_type: String,
    /// The clock the whole round ran under (Unix seconds). Fixed input, never sampled here.
    pub now: u64,
    /// The debrid services the round considered (wire strings, input order).
    pub services: Vec<String>,
    /// The engine's fetch plan (circuit-open sources skipped, sorted by addon id).
    pub plan: Vec<FetchRequest>,
    /// Sources whose outcomes survived settlement.
    pub survivors: Vec<String>,
    /// Sources isolated at settlement, with the reason.
    pub failed: Vec<FailedAddon>,
    /// The ranked, player-ready order. Each entry carries its structured cacheStatus.
    pub streams: Vec<RankedStreamOut>,
    /// The kernel's debrid resolve plan over the ranked sources.
    pub resolve: ResolveSection,
    /// The updated circuit-breaker snapshot a host would upsert.
    pub circuit: BreakerRegistry,
}

/// One ranked stream: the kernel's ranking decision joined back onto the settled stream it ranks.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RankedStreamOut {
    /// Position in the ranked order (0 = play first).
    pub rank: usize,
    /// Index into the settled stream list (the kernel's `raw_index`).
    pub raw_index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub info_hash: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    /// The kernel's fixed-point score (milli-points, byte-reproducible; no float anywhere).
    pub score: i64,
    pub tier: Tier,
    pub reasons: Vec<String>,
    pub is_dolby_vision: bool,
    pub is_hdr: bool,
    pub audio: Audio,
    /// The structured cache status: how this stream's advertised debrid caching intersects the
    /// user's enabled services.
    pub cache_status: CacheStatus,
}

/// The structured cache status of one stream against the user's enabled debrid services, derived
/// with the kernel's own `cached_on` matcher so it can never disagree with the ranking bonus.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CacheStatus {
    /// `cached` when an advertised service matches an enabled user service; `uncached` when the
    /// stream advertises caching but none of it is usable by this user; `unknown` when the stream
    /// carries no cache facts at all (a plain stream must resolve live).
    pub state: CacheState,
    /// The user's enabled services this stream is instant on (wire strings, user order).
    pub services: Vec<String>,
    /// Every service the stream itself advertises as caching it (verbatim).
    pub advertised: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CacheState {
    Cached,
    Uncached,
    Unknown,
}

/// The kernel's debrid resolve planning over the ranked streams: which method to try in which
/// order (direct first, then debrid-cached, then debrid-uncached, then P2P).
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveSection {
    /// The candidate sources, in ranked-stream order (`sourceIndex` in `plan` points here).
    pub sources: Vec<ResolveSource>,
    /// The ordered resolve plan (rank 0 = try first).
    pub plan: Vec<ResolveStep>,
    /// The direct https URL the plan resolves to right now, when its first step is a Direct
    /// source. A debrid-cached first step instead needs a live unrestrict (the Phase 2 stores).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_url: Option<String>,
}

/// Derive the structured [`CacheStatus`] for one stream. Grounded on the kernel's typed
/// `behaviorHints.vortx.cachedServices` side-channel and its case-insensitive `cached_on` matcher.
pub fn cache_status(stream: &Stream, user_services: &[DebridService]) -> CacheStatus {
    let advertised: Vec<String> = stream
        .behavior_hints
        .as_ref()
        .and_then(|h| h.vortx.as_ref())
        .map(|v| v.cached_services.clone())
        .unwrap_or_default();
    if advertised.is_empty() {
        return CacheStatus {
            state: CacheState::Unknown,
            services: Vec::new(),
            advertised,
        };
    }
    let services: Vec<String> = user_services
        .iter()
        .filter(|svc| cached_on(&advertised, &[svc.as_wire()]))
        .map(|svc| svc.as_wire().to_string())
        .collect();
    let state = if services.is_empty() {
        CacheState::Uncached
    } else {
        CacheState::Cached
    };
    CacheStatus {
        state,
        services,
        advertised,
    }
}

/// Join one ranked entry back onto the settled stream it indexes.
pub fn ranked_out(
    rank: usize,
    ranked: &RankedStream,
    stream: &Stream,
    user_services: &[DebridService],
) -> RankedStreamOut {
    RankedStreamOut {
        rank,
        raw_index: ranked.raw_index,
        name: stream.name.clone(),
        title: stream.title.clone(),
        url: stream.url.clone(),
        info_hash: stream.info_hash.clone(),
        file_idx: stream.file_idx,
        score: ranked.score,
        tier: ranked.tier,
        reasons: ranked.reasons.clone(),
        is_dolby_vision: ranked.is_dolby_vision,
        is_hdr: ranked.is_hdr,
        audio: ranked.audio,
        cache_status: cache_status(stream, user_services),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_protocol::{StreamBehaviorHints, VortxStreamHints};

    fn stream_with_services(services: &[&str]) -> Stream {
        Stream {
            name: Some("x".into()),
            behavior_hints: Some(StreamBehaviorHints {
                vortx: Some(VortxStreamHints {
                    cached_services: services.iter().map(|s| s.to_string()).collect(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn a_plain_stream_is_unknown() {
        let status = cache_status(&Stream::default(), &[DebridService::RealDebrid]);
        assert_eq!(status.state, CacheState::Unknown);
        assert!(status.services.is_empty() && status.advertised.is_empty());
    }

    #[test]
    fn advertised_but_unusable_is_uncached() {
        let status = cache_status(
            &stream_with_services(&["premiumize"]),
            &[DebridService::RealDebrid],
        );
        assert_eq!(status.state, CacheState::Uncached);
        assert!(status.services.is_empty());
        assert_eq!(status.advertised, vec!["premiumize"]);
    }

    #[test]
    fn a_user_service_match_is_cached_and_case_insensitive() {
        let status = cache_status(
            &stream_with_services(&["RealDebrid", "torbox"]),
            &[DebridService::TorBox, DebridService::RealDebrid],
        );
        assert_eq!(status.state, CacheState::Cached);
        // User order, canonical wire strings.
        assert_eq!(status.services, vec!["torbox", "realdebrid"]);
    }

    #[test]
    fn cache_status_agrees_with_the_kernel_ranking_flag() {
        // The invariant: state == Cached exactly when the kernel would grant the cached bonus.
        let user = [DebridService::RealDebrid];
        for stream in [
            Stream::default(),
            stream_with_services(&["realdebrid"]),
            stream_with_services(&["torbox"]),
        ] {
            let ours = cache_status(&stream, &user).state == CacheState::Cached;
            let kernels = vortx_source::stream_is_cached(&stream, &user);
            assert_eq!(ours, kernels);
        }
    }
}
