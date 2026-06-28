//! Cross-language conformance + property tests for resolve_streams(): the bridge from the source registry
//! to the deadline-bounded host fan-out. A mock Fetch stands in for the host, so registry routing, per-source
//! fetch planning, failure isolation, the uniform item-key parse contract, and end-to-end determinism are all
//! exercised with zero I/O. The conformance suite compares the serialized ResolvedStreams wire form (Stream is
//! not PartialEq, so the wire form is the cross-language oracle).

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_protocol::Stream;
use vortx_source::{
    resolve_streams, BreakerRegistry, CircuitConfig, Fetch, FetchOutcome, FetchRequest, ResourceKind,
    ResourceRequest, Source, SourceError, SourceKind, SourceRegistry,
};

/// A conformance/property source: it declares its caps, whether `supports()` passes, and whether it plans a
/// fetch (a `plans=false` source is the "local-only / unwired" case that is routed but never fetched).
struct ConfSource {
    id: String,
    caps: Vec<ResourceKind>,
    supports: bool,
    plans: bool,
}

impl Source for ConfSource {
    fn id(&self) -> &str {
        &self.id
    }
    fn kind(&self) -> SourceKind {
        SourceKind::StremioAddon
    }
    fn capabilities(&self) -> &[ResourceKind] {
        &self.caps
    }
    fn supports(&self, _req: &ResourceRequest) -> bool {
        self.supports
    }
    fn plan(&self, _req: &ResourceRequest, budget_ms: u64) -> Option<FetchRequest> {
        if self.plans && self.supports {
            Some(FetchRequest {
                addon_id: self.id.clone(),
                url: format!("http://{}/", self.id),
                budget_ms,
            })
        } else {
            None
        }
    }
    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        Err(SourceError::NotImplemented)
    }
}

struct MockFetch {
    map: BTreeMap<String, FetchOutcome>,
}

impl Fetch for MockFetch {
    fn fetch(&self, req: &FetchRequest) -> FetchOutcome {
        self.map
            .get(&req.addon_id)
            .cloned()
            .unwrap_or(FetchOutcome::Timeout)
    }
}

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct SourceDecl {
    id: String,
    caps: Vec<ResourceKind>,
    supports: bool,
    plans: bool,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    sources: Vec<SourceDecl>,
    request: ResourceRequest,
    #[serde(default)]
    breakers: BreakerRegistry,
    now: u64,
    budget_ms: u64,
    outcomes: BTreeMap<String, FetchOutcome>,
    expect: Value,
}

const SUITE: &str = include_str!("../conformance/resolve_vectors.json");

#[test]
fn resolve_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse resolve suite");
    assert!(suite.cases.len() >= 6);
    for case in &suite.cases {
        let mut reg = SourceRegistry::new();
        for s in &case.sources {
            reg.install(Box::new(ConfSource {
                id: s.id.clone(),
                caps: s.caps.clone(),
                supports: s.supports,
                plans: s.plans,
            }));
        }
        let mut breakers = case.breakers.clone();
        let fetch = MockFetch {
            map: case.outcomes.clone(),
        };
        let out = resolve_streams(
            &reg,
            &case.request,
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            case.now,
            case.budget_ms,
        );
        let got = serde_json::to_value(&out).expect("serialize resolved");
        assert_eq!(got, case.expect, "resolve drifted for {}", case.name);
    }
}

// --- property tests ---

/// A set of (id -> ok-item-count or failure) declarations. Ok items are always valid Stream JSON so the
/// parse count is exact; a failure carries no items.
fn cases() -> impl Strategy<Value = BTreeMap<String, Option<usize>>> {
    // Some(n) = Ok with n stream items; None = a malformed failure.
    prop::collection::btree_map("[a-e]", prop::option::of(0usize..3), 0..5)
}

fn registry_of(spec: &BTreeMap<String, Option<usize>>) -> SourceRegistry {
    let mut reg = SourceRegistry::new();
    for id in spec.keys() {
        reg.install(Box::new(ConfSource {
            id: id.clone(),
            caps: vec![ResourceKind::Stream],
            supports: true,
            plans: true,
        }));
    }
    reg
}

fn fetch_of(spec: &BTreeMap<String, Option<usize>>) -> MockFetch {
    let map = spec
        .iter()
        .map(|(id, outcome)| {
            let o = match outcome {
                Some(n) => FetchOutcome::Ok {
                    items: (0..*n).map(|k| format!(r#"{{"url":"u{id}{k}"}}"#)).collect(),
                },
                None => FetchOutcome::Malformed,
            };
            (id.clone(), o)
        })
        .collect();
    MockFetch { map }
}

fn req() -> ResourceRequest {
    ResourceRequest::new(ResourceKind::Stream, "movie", "tt1")
}

proptest! {
    // Same inputs always resolve to the same wire form, however the host parallelizes.
    #[test]
    fn resolve_streams_is_deterministic(spec in cases(), now in 0u64..10_000) {
        let reg = registry_of(&spec);
        let fetch = fetch_of(&spec);
        let mut b1 = BreakerRegistry::new();
        let mut b2 = BreakerRegistry::new();
        let a = resolve_streams(&reg, &req(), &fetch, &mut b1, &CircuitConfig::default(), now, 5000);
        let b = resolve_streams(&reg, &req(), &fetch, &mut b2, &CircuitConfig::default(), now, 5000);
        prop_assert_eq!(
            serde_json::to_value(&a).unwrap(),
            serde_json::to_value(&b).unwrap()
        );
    }

    // Failures never drop a good source's streams; survivors+failed partition the planned set; the parsed
    // stream count equals the exact number of ok items across surviving sources.
    #[test]
    fn failures_isolate_and_the_partition_holds(spec in cases()) {
        let reg = registry_of(&spec);
        let fetch = fetch_of(&spec);
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(&reg, &req(), &fetch, &mut breakers, &CircuitConfig::default(), 1000, 5000);

        let ok_ids: Vec<&String> = spec.iter().filter(|(_, o)| o.is_some()).map(|(id, _)| id).collect();
        let fail_count = spec.values().filter(|o| o.is_none()).count();
        let total_items: usize = spec.values().filter_map(|o| *o).sum();

        // Every ok source survived; every failure was isolated.
        for id in &ok_ids {
            prop_assert!(out.survivors.contains(id), "missing survivor {}", id);
        }
        prop_assert_eq!(out.survivors.len(), ok_ids.len());
        prop_assert_eq!(out.failed.len(), fail_count);
        // No open breakers, so survivors+failed exactly partition the planned (= all, since every source plans).
        prop_assert_eq!(out.survivors.len() + out.failed.len(), spec.len());
        // Every ok item parsed into exactly one stream; a failure contributed none.
        prop_assert_eq!(out.streams.len(), total_items);
    }
}
