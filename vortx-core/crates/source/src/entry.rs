//! A lightweight, serializable snapshot of an installed source, plus the PURE fan-out planner over a set of
//! them. This is what lets the clockless engine drive a stream LOAD without owning any source state: the host
//! snapshots its installed sources as [`SourceEntry`]s and passes them (with a circuit-breaker snapshot) into
//! a resolve query; [`plan_streams`] routes the request (capability + id-space) and returns the deadline-
//! stamped [`FetchRequest`]s to perform, circuit-open sources skipped, sorted by addon id. The host executes
//! the plan via the [`crate::Fetch`] boundary and settles it (the settle phase, host-side, updates breakers).
//!
//! PURE: no I/O, no state mutation. The breaker snapshot is read-only here; the engine never holds it. This
//! is the stateless half of the LOAD effect model: plan (here, pure) then settle (host-applied).

use serde::{Deserialize, Serialize};
use vortx_protocol::ResourcePath;

use crate::fanout::{BreakerRegistry, CircuitConfig};
use crate::request::{id_space_allows, ResourceKind, ResourceRequest};
use crate::source::SourceKind;
use crate::transport::{plan_fanout, source_base, FetchRequest};

/// A flat, serializable descriptor of one installed source: enough to ROUTE a request (capability +
/// id-space) and PLAN its fetch URL, without the full `Source` object. The host snapshots its registry as
/// these so the pure engine can plan a fan-out with no state of its own. `url` is the source's transport (or
/// manifest) URL; the resource URL is built from it with the byte-exact Stremio grammar.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceEntry {
    pub id: String,
    pub url: String,
    pub kind: SourceKind,
    #[serde(default)]
    pub capabilities: Vec<ResourceKind>,
    #[serde(default)]
    pub types: Vec<String>,
    #[serde(default, rename = "idPrefixes")]
    pub id_prefixes: Vec<String>,
}

impl SourceEntry {
    /// Whether this source can answer `req` (capability + type + content id-prefix gate).
    fn supports(&self, req: &ResourceRequest) -> bool {
        id_space_allows(&self.capabilities, &self.types, &self.id_prefixes, req)
    }
}

/// Plan the host fan-out for `req` over a snapshot of installed sources: route by capability + id-space,
/// build each matching source's fetch URL (byte-exact Stremio grammar), and circuit-filter + sort via
/// [`plan_fanout`] (a circuit-open source still cooling is skipped). PURE and deterministic (sorted addon
/// id); the breaker snapshot is read-only. The host realizes the returned requests through the `Fetch`
/// boundary, then settles them (the settle phase updates breakers host-side).
pub fn plan_streams(
    entries: &[SourceEntry],
    req: &ResourceRequest,
    breakers: &BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
    budget_ms: u64,
) -> Vec<FetchRequest> {
    let candidates: Vec<(String, String)> = entries
        .iter()
        .filter(|e| e.supports(req))
        .map(|e| (e.id.clone(), ResourcePath::from(req).to_url(source_base(&e.url))))
        .collect();
    plan_fanout(&candidates, breakers, cfg, now, budget_ms)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fanout::{BreakerState, CircuitBreaker};

    fn entry(id: &str, url: &str, caps: &[ResourceKind], types: &[&str], prefixes: &[&str]) -> SourceEntry {
        SourceEntry {
            id: id.to_string(),
            url: url.to_string(),
            kind: SourceKind::StremioAddon,
            capabilities: caps.to_vec(),
            types: types.iter().map(|t| t.to_string()).collect(),
            id_prefixes: prefixes.iter().map(|p| p.to_string()).collect(),
        }
    }

    fn stream_req() -> ResourceRequest {
        ResourceRequest::new(ResourceKind::Stream, "movie", "tt0111161")
    }

    #[test]
    fn plans_matching_sources_in_sorted_addon_id_order_with_correct_urls() {
        let entries = vec![
            entry("zeta", "https://z.tv/manifest.json", &[ResourceKind::Stream], &["movie"], &["tt"]),
            entry("alpha", "https://a.tv/manifest.vortx.json", &[ResourceKind::Stream], &["movie"], &["tt"]),
        ];
        let plan = plan_streams(
            &entries,
            &stream_req(),
            &BreakerRegistry::new(),
            &CircuitConfig::default(),
            1000,
            5000,
        );
        // Sorted by addon id; URLs built off the stripped base (both manifest suffixes handled).
        assert_eq!(plan.len(), 2);
        assert_eq!(plan[0].addon_id, "alpha");
        assert_eq!(plan[0].url, "https://a.tv/stream/movie/tt0111161.json");
        assert_eq!(plan[0].budget_ms, 5000);
        assert_eq!(plan[1].addon_id, "zeta");
        assert_eq!(plan[1].url, "https://z.tv/stream/movie/tt0111161.json");
    }

    #[test]
    fn routes_out_sources_that_cannot_answer() {
        let entries = vec![
            entry("meta-only", "https://m.tv/manifest.json", &[ResourceKind::Meta], &[], &[]),
            entry("wrong-prefix", "https://w.tv/manifest.json", &[ResourceKind::Stream], &[], &["kitsu"]),
            entry("good", "https://g.tv/manifest.json", &[ResourceKind::Stream], &[], &["tt"]),
        ];
        let plan = plan_streams(
            &entries,
            &stream_req(),
            &BreakerRegistry::new(),
            &CircuitConfig::default(),
            1000,
            5000,
        );
        assert_eq!(plan.iter().map(|r| r.addon_id.as_str()).collect::<Vec<_>>(), vec!["good"]);
    }

    #[test]
    fn a_circuit_open_source_still_cooling_is_skipped() {
        let cfg = CircuitConfig {
            failure_threshold: 3,
            cooldown_secs: 300,
        };
        let mut breakers = BreakerRegistry::new();
        breakers.insert(
            "bad".into(),
            CircuitBreaker {
                consecutive_failures: 3,
                state: BreakerState::Open,
                opened_at: 1000,
            },
        );
        let entries = vec![
            entry("good", "https://g.tv/manifest.json", &[ResourceKind::Stream], &[], &["tt"]),
            entry("bad", "https://b.tv/manifest.json", &[ResourceKind::Stream], &[], &["tt"]),
        ];
        // now=1100 -> 100s < 300 cooldown -> "bad" skipped.
        let plan = plan_streams(&entries, &stream_req(), &breakers, &cfg, 1100, 5000);
        assert_eq!(plan.iter().map(|r| r.addon_id.as_str()).collect::<Vec<_>>(), vec!["good"]);
    }
}
