//! Resolve a resource request to typed streams by driving the host fan-out across every matching source.
//! This is the bridge that closes the gap between the pure [`SourceRegistry`] and the deadline-bounded
//! [`crate::transport`]: registry routing picks the candidate sources (capability + id-space gated), each
//! source plans its OWN host [`FetchRequest`] via [`Source::plan`], the shared [`run_fanout`] realizes them
//! through the host [`Fetch`] boundary (skipping circuit-open sources, isolating failures, settling partial
//! results), and the merged item keys are parsed back into typed [`Stream`]s.
//!
//! The kernel still performs ZERO network I/O: the host supplies the bytes through `Fetch`, the engine owns
//! WHICH sources to query, in WHAT order, and HOW to fuse the result. Determinism carries end to end:
//! candidates are planned in registry (priority) order and merged in sorted-addon-id order, so the resolved
//! stream list is byte-identical across Apple/Android/wasm.
//!
//! The item-key contract is uniform: the host has already turned each source's 2xx body into individual
//! validated stream JSON strings, so [`parse_stream_item`] deserializes every key the same way regardless of
//! source kind, and a malformed key is dropped rather than poisoning the batch.

use serde::{Deserialize, Serialize};
use vortx_protocol::{MetaDetail, MetaPreview, Stream};

use crate::fanout::{Aggregate, BreakerRegistry, CircuitConfig, FailedAddon};
use crate::registry::SourceRegistry;
use crate::request::ResourceRequest;
use crate::transport::{run_fanout, settle_fanout, Fetch, FetchOutcome, FetchRequest};

/// The result of resolving a request across the matching sources: the parsed streams (the union of every
/// surviving source, in the fan-out's deterministic sorted-addon-id order), plus which sources survived and
/// which failed (isolated, with the reason). No `PartialEq`: [`Stream`] is not `PartialEq`, so equality is
/// compared on the serialized wire form, which is the cross-language contract anyway.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolvedStreams {
    pub streams: Vec<Stream>,
    pub survivors: Vec<String>,
    pub failed: Vec<FailedAddon>,
}

/// Parse one host-returned item key into a typed [`Stream`]. The fan-out's item-key contract is uniform:
/// the host turned a 2xx body into individual validated stream JSON strings, so the kernel parses each the
/// same way regardless of source kind. A malformed key yields `None` (dropped), never a panic.
pub fn parse_stream_item(item: &str) -> Option<Stream> {
    serde_json::from_str::<Stream>(item).ok()
}

/// Resolve `req` to streams by fanning out across every source that can answer it. Pure over the injected
/// host [`Fetch`]: registry routing gates by capability + id-space, each source plans its own
/// [`FetchRequest`], [`run_fanout`] realizes + settles them, and the merged item keys parse back into typed
/// [`Stream`]s. A source that cannot plan a fetch (local-only, or unwired) is simply not queried; a failing
/// or circuit-open source never removes another source's streams.
pub fn resolve_streams<F: Fetch + ?Sized>(
    registry: &SourceRegistry,
    req: &ResourceRequest,
    fetcher: &F,
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
    budget_ms: u64,
) -> ResolvedStreams {
    let candidates: Vec<(String, String)> = registry
        .resolve(req)
        .into_iter()
        .filter_map(|s| s.plan(req, budget_ms))
        .map(|fr| (fr.addon_id, fr.url))
        .collect();
    let agg: Aggregate = run_fanout(fetcher, &candidates, breakers, cfg, now, budget_ms);
    resolved_from(agg)
}

/// Settle the host's outcomes for an already-issued [`FetchRequest`] plan into typed streams (the SETTLE half
/// of the stateless LOAD effect model). The PLAN phase returned the requests; the host realized them through
/// its `Fetch` boundary and now hands back the outcomes. `settle_fanout` isolates failures (a missing outcome
/// settles as Timeout) and updates the breakers IN PLACE; the parsed merged items become the typed streams.
/// Pure over the breaker snapshot: the engine never holds it, so the caller passes a snapshot in and reads
/// the mutated snapshot back out (the host upserts it). The kernel itself stays stateless.
pub fn settle_streams(
    plan: &[FetchRequest],
    outcomes: &[(String, FetchOutcome)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> ResolvedStreams {
    resolved_from(settle_fanout(plan, outcomes, breakers, cfg, now))
}

/// Parse a settled [`Aggregate`] (the merged item keys + survivor/failure attribution) into typed streams.
/// Shared by the end-to-end [`resolve_streams`] and the settle-only [`settle_streams`] so both agree on the
/// uniform item-key parse contract.
fn resolved_from(agg: Aggregate) -> ResolvedStreams {
    ResolvedStreams {
        streams: agg.items.iter().filter_map(|k| parse_stream_item(k)).collect(),
        survivors: agg.survivors,
        failed: agg.failed,
    }
}

/// The result of a CATALOG LOAD: the parsed catalog rows (the deterministic union of every surviving
/// source), plus survivor/failure attribution. The catalog analogue of [`ResolvedStreams`]: the SAME LOAD
/// effect model and fan-out machinery, only the item type differs ([`MetaPreview`] instead of [`Stream`]).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolvedCatalog {
    pub metas: Vec<MetaPreview>,
    pub survivors: Vec<String>,
    pub failed: Vec<FailedAddon>,
}

/// Parse one host-returned item key into a typed [`MetaPreview`] (a catalog row). Same uniform item-key
/// contract as [`parse_stream_item`]: the host turned a 2xx catalog body into individual validated meta JSON
/// strings, so a malformed key yields `None` (dropped), never a panic.
pub fn parse_catalog_item(item: &str) -> Option<MetaPreview> {
    serde_json::from_str::<MetaPreview>(item).ok()
}

/// Settle the host's outcomes for an already-issued catalog [`FetchRequest`] plan into typed catalog rows (the
/// SETTLE half of the LOAD effect model, catalog flavor). Reuses the EXACT same [`settle_fanout`] as streams
/// (failure isolation, missing -> Timeout, breaker update in place); only the item parse differs. Pure over
/// the breaker snapshot: the caller passes it in and reads the mutated snapshot back out.
pub fn settle_catalog(
    plan: &[FetchRequest],
    outcomes: &[(String, FetchOutcome)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> ResolvedCatalog {
    resolved_catalog_from(settle_fanout(plan, outcomes, breakers, cfg, now))
}

/// Parse a settled [`Aggregate`] into catalog rows (the catalog twin of [`resolved_from`]).
fn resolved_catalog_from(agg: Aggregate) -> ResolvedCatalog {
    ResolvedCatalog {
        metas: agg.items.iter().filter_map(|k| parse_catalog_item(k)).collect(),
        survivors: agg.survivors,
        failed: agg.failed,
    }
}

/// The result of a META LOAD: a SINGULAR meta detail (a title has one canonical detail, so the merge picks
/// the highest-priority source that answered, not a list), plus survivor/failure attribution. The third leg
/// of the stream/catalog/meta LOAD trio; same effect model and fan-out, only the item type + arity differ.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolvedMeta {
    pub meta: Option<MetaDetail>,
    pub survivors: Vec<String>,
    pub failed: Vec<FailedAddon>,
}

/// Parse one host-returned item key into a typed [`MetaDetail`]. Same uniform item-key contract as the
/// stream/catalog parsers; a malformed key yields `None` (dropped), never a panic.
pub fn parse_meta_item(item: &str) -> Option<MetaDetail> {
    serde_json::from_str::<MetaDetail>(item).ok()
}

/// Settle the host's outcomes for an already-issued meta [`FetchRequest`] plan into a SINGULAR meta detail
/// (the SETTLE half of the LOAD effect model, meta flavor). Reuses the EXACT same [`settle_fanout`] as
/// streams/catalog (failure isolation, missing -> Timeout, breaker update); the merged items are in
/// deterministic sorted-addon-id order, so the FIRST successfully-parsed item is the highest-priority source's
/// detail. Pure over the breaker snapshot.
pub fn settle_meta(
    plan: &[FetchRequest],
    outcomes: &[(String, FetchOutcome)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> ResolvedMeta {
    resolved_meta_from(settle_fanout(plan, outcomes, breakers, cfg, now))
}

/// Parse a settled [`Aggregate`] into a singular meta detail: the first parseable item wins (highest-priority
/// source that answered, since items are merged in sorted-addon-id order).
fn resolved_meta_from(agg: Aggregate) -> ResolvedMeta {
    ResolvedMeta {
        meta: agg.items.iter().find_map(|k| parse_meta_item(k)),
        survivors: agg.survivors,
        failed: agg.failed,
    }
}

/// The RAW merged item keys of a settled LOAD, for a resource whose typed item lives OUTSIDE this crate's
/// dependency set (subtitles, whose `SubtitleTrack` is in `vortx-subtitles`). The caller (which has the typed
/// dep) parses the keys itself. Same `settle_fanout` machinery + survivor/failure attribution; the items are
/// the deterministic sorted-addon-id union, so the caller's parse stays cross-platform-stable.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ResolvedItems {
    pub items: Vec<String>,
    pub survivors: Vec<String>,
    pub failed: Vec<FailedAddon>,
}

/// Settle a LOAD into its RAW merged item keys (the generic SETTLE half, for a resource this crate cannot
/// type because its item lives in another crate). Reuses the EXACT same `settle_fanout` as the typed settles;
/// the caller parses each returned key into its own type. Pure over the breaker snapshot.
pub fn settle_items(
    plan: &[FetchRequest],
    outcomes: &[(String, FetchOutcome)],
    breakers: &mut BreakerRegistry,
    cfg: &CircuitConfig,
    now: u64,
) -> ResolvedItems {
    let agg = settle_fanout(plan, outcomes, breakers, cfg, now);
    ResolvedItems {
        items: agg.items,
        survivors: agg.survivors,
        failed: agg.failed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::request::ResourceKind;
    use crate::source::{Source, SourceKind};
    use crate::transport::{FetchOutcome, FetchRequest};
    use crate::SourceError;
    use std::collections::BTreeMap;

    /// A test source that plans a fetch keyed by its id and serves a fixed resource set.
    struct PlanningSource {
        id: String,
        caps: Vec<ResourceKind>,
        supports_all: bool,
    }

    impl Source for PlanningSource {
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
            self.supports_all
        }
        fn plan(&self, _req: &ResourceRequest, budget_ms: u64) -> Option<FetchRequest> {
            Some(FetchRequest {
                addon_id: self.id.clone(),
                url: format!("http://{}/stream", self.id),
                budget_ms,
            })
        }
        fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
            Err(SourceError::NotImplemented)
        }
    }

    /// A local-only source: it can answer the capability gate but plans NO fetch (default plan -> None).
    struct LocalOnlySource {
        id: String,
        caps: Vec<ResourceKind>,
    }

    impl Source for LocalOnlySource {
        fn id(&self) -> &str {
            &self.id
        }
        fn kind(&self) -> SourceKind {
            SourceKind::NativeVortx
        }
        fn capabilities(&self) -> &[ResourceKind] {
            &self.caps
        }
        fn supports(&self, _req: &ResourceRequest) -> bool {
            true
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

    fn stream_item(url: &str) -> String {
        format!(r#"{{"url":"{url}"}}"#)
    }

    fn catalog_item(id: &str, name: &str) -> String {
        format!(r#"{{"id":"{id}","type":"movie","name":"{name}"}}"#)
    }

    fn meta_item(id: &str, name: &str) -> String {
        format!(r#"{{"id":"{id}","type":"movie","name":"{name}"}}"#)
    }

    fn req() -> ResourceRequest {
        ResourceRequest::new(ResourceKind::Stream, "movie", "tt1")
    }

    #[test]
    fn fuses_streams_from_every_surviving_source() {
        let mut reg = SourceRegistry::new();
        reg.install(Box::new(PlanningSource {
            id: "zeta".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: true,
        }));
        reg.install(Box::new(PlanningSource {
            id: "alpha".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: true,
        }));
        let fetch = MockFetch {
            map: BTreeMap::from([
                (
                    "zeta".into(),
                    FetchOutcome::Ok {
                        items: vec![stream_item("http://z/1")],
                    },
                ),
                (
                    "alpha".into(),
                    FetchOutcome::Ok {
                        items: vec![stream_item("http://a/1")],
                    },
                ),
            ]),
        };
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(
            &reg,
            &req(),
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        // Sorted-addon-id order: alpha before zeta.
        assert_eq!(out.streams.len(), 2);
        assert_eq!(out.streams[0].url.as_deref(), Some("http://a/1"));
        assert_eq!(out.streams[1].url.as_deref(), Some("http://z/1"));
        assert_eq!(out.survivors, vec!["alpha", "zeta"]);
        assert!(out.failed.is_empty());
    }

    #[test]
    fn a_malformed_source_is_isolated_and_keeps_the_good_streams() {
        let mut reg = SourceRegistry::new();
        reg.install(Box::new(PlanningSource {
            id: "good".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: true,
        }));
        reg.install(Box::new(PlanningSource {
            id: "poison".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: true,
        }));
        let fetch = MockFetch {
            map: BTreeMap::from([
                (
                    "good".into(),
                    FetchOutcome::Ok {
                        items: vec![stream_item("http://g/1")],
                    },
                ),
                ("poison".into(), FetchOutcome::Malformed),
            ]),
        };
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(
            &reg,
            &req(),
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        assert_eq!(out.streams.len(), 1);
        assert_eq!(out.streams[0].url.as_deref(), Some("http://g/1"));
        assert_eq!(out.survivors, vec!["good"]);
        assert_eq!(out.failed.len(), 1);
        assert_eq!(out.failed[0].addon_id, "poison");
    }

    #[test]
    fn an_unparseable_item_key_is_dropped_but_the_source_still_survives() {
        let mut reg = SourceRegistry::new();
        reg.install(Box::new(PlanningSource {
            id: "src".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: true,
        }));
        let fetch = MockFetch {
            map: BTreeMap::from([(
                "src".into(),
                FetchOutcome::Ok {
                    items: vec!["not json".into(), stream_item("http://s/1")],
                },
            )]),
        };
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(
            &reg,
            &req(),
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        // The "ok" outcome kept the source a survivor; only the bad key was dropped.
        assert_eq!(out.streams.len(), 1);
        assert_eq!(out.streams[0].url.as_deref(), Some("http://s/1"));
        assert_eq!(out.survivors, vec!["src"]);
    }

    #[test]
    fn a_source_that_cannot_answer_is_never_queried() {
        let mut reg = SourceRegistry::new();
        // Has the cap but supports() rejects -> not in registry.resolve -> never planned.
        reg.install(Box::new(PlanningSource {
            id: "wrong-id".into(),
            caps: vec![ResourceKind::Stream],
            supports_all: false,
        }));
        // Lacks the cap entirely -> not in registry.resolve.
        reg.install(Box::new(PlanningSource {
            id: "meta-only".into(),
            caps: vec![ResourceKind::Meta],
            supports_all: true,
        }));
        let fetch = MockFetch {
            map: BTreeMap::new(),
        };
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(
            &reg,
            &req(),
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        assert!(out.streams.is_empty());
        assert!(out.survivors.is_empty());
        assert!(out.failed.is_empty());
    }

    #[test]
    fn a_local_only_source_is_routed_but_plans_no_fetch() {
        let mut reg = SourceRegistry::new();
        reg.install(Box::new(LocalOnlySource {
            id: "local".into(),
            caps: vec![ResourceKind::Stream],
        }));
        let fetch = MockFetch {
            map: BTreeMap::new(),
        };
        let mut breakers = BreakerRegistry::new();
        let out = resolve_streams(
            &reg,
            &req(),
            &fetch,
            &mut breakers,
            &CircuitConfig::default(),
            1000,
            5000,
        );
        // It matched the registry gate but plan() -> None, so it is never turned into a fetch candidate.
        assert!(out.streams.is_empty());
        assert!(out.survivors.is_empty());
        assert!(out.failed.is_empty());
    }

    #[test]
    fn settle_streams_parses_outcomes_isolates_failures_and_updates_breakers() {
        let plan = vec![
            FetchRequest { addon_id: "good".into(), url: "http://g".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "poison".into(), url: "http://p".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "slow".into(), url: "http://s".into(), budget_ms: 5000 },
        ];
        // The host returned good + poison; "slow" is missing -> settles as Timeout.
        let outcomes = vec![
            (
                "good".to_string(),
                FetchOutcome::Ok {
                    items: vec![stream_item("http://g/1")],
                },
            ),
            ("poison".to_string(), FetchOutcome::Malformed),
        ];
        let mut breakers = BreakerRegistry::new();
        let out = settle_streams(&plan, &outcomes, &mut breakers, &CircuitConfig::default(), 1000);
        assert_eq!(out.streams.len(), 1);
        assert_eq!(out.streams[0].url.as_deref(), Some("http://g/1"));
        assert_eq!(out.survivors, vec!["good"]);
        // poison (malformed) + slow (missing -> timeout) are both isolated, sorted by addon id.
        assert_eq!(out.failed.len(), 2);
        // The breakers were updated in place: the good source reset, the two failures recorded.
        assert_eq!(breakers.get("good").unwrap().consecutive_failures, 0);
        assert_eq!(breakers.get("poison").unwrap().consecutive_failures, 1);
        assert_eq!(breakers.get("slow").unwrap().consecutive_failures, 1);
    }

    #[test]
    fn settle_catalog_parses_metas_and_isolates_failures_like_streams() {
        // Same LOAD machinery as settle_streams; only the item type differs (MetaPreview, sorted-id merge).
        let plan = vec![
            FetchRequest { addon_id: "alpha".into(), url: "http://a".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "zeta".into(), url: "http://z".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "down".into(), url: "http://d".into(), budget_ms: 5000 },
        ];
        let outcomes = vec![
            (
                "alpha".to_string(),
                FetchOutcome::Ok { items: vec![catalog_item("tt1", "A"), "not json".into()] },
            ),
            (
                "zeta".to_string(),
                FetchOutcome::Ok { items: vec![catalog_item("tt2", "Z")] },
            ),
            ("down".to_string(), FetchOutcome::Error),
        ];
        let mut breakers = BreakerRegistry::new();
        let out = settle_catalog(&plan, &outcomes, &mut breakers, &CircuitConfig::default(), 1000);
        // alpha before zeta (sorted-id merge); the bad key was dropped, the Error source isolated.
        assert_eq!(out.metas.len(), 2);
        assert_eq!(out.metas[0].id, "tt1");
        assert_eq!(out.metas[1].id, "tt2");
        assert_eq!(out.survivors, vec!["alpha", "zeta"]);
        assert_eq!(out.failed.len(), 1);
        assert_eq!(out.failed[0].addon_id, "down");
    }

    #[test]
    fn settle_meta_picks_the_first_surviving_source_and_isolates_failures() {
        // Singular meta: the highest-priority source that answered wins (sorted-id merge -> alpha first).
        let plan = vec![
            FetchRequest { addon_id: "alpha".into(), url: "http://a".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "zeta".into(), url: "http://z".into(), budget_ms: 5000 },
        ];
        let outcomes = vec![
            ("alpha".to_string(), FetchOutcome::Ok { items: vec![meta_item("tt1", "Alpha Detail")] }),
            ("zeta".to_string(), FetchOutcome::Ok { items: vec![meta_item("tt1", "Zeta Detail")] }),
        ];
        let mut breakers = BreakerRegistry::new();
        let out = settle_meta(&plan, &outcomes, &mut breakers, &CircuitConfig::default(), 1000);
        let meta = out.meta.expect("a meta");
        assert_eq!(meta.name, "Alpha Detail"); // alpha (first by id) wins
        assert_eq!(out.survivors, vec!["alpha", "zeta"]);

        // No source answers -> None (and the missing sources are isolated as Timeout).
        let mut b2 = BreakerRegistry::new();
        let empty = settle_meta(&plan, &[], &mut b2, &CircuitConfig::default(), 1000);
        assert!(empty.meta.is_none());
        assert_eq!(empty.failed.len(), 2);
    }

    #[test]
    fn settle_items_returns_the_raw_merged_keys_in_sorted_order() {
        // The generic raw settle: the caller parses the keys (subtitles, whose type is in another crate).
        let plan = vec![
            FetchRequest { addon_id: "alpha".into(), url: "http://a".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "zeta".into(), url: "http://z".into(), budget_ms: 5000 },
            FetchRequest { addon_id: "down".into(), url: "http://d".into(), budget_ms: 5000 },
        ];
        let outcomes = vec![
            ("alpha".to_string(), FetchOutcome::Ok { items: vec!["a1".into(), "a2".into()] }),
            ("zeta".to_string(), FetchOutcome::Ok { items: vec!["z1".into()] }),
            ("down".to_string(), FetchOutcome::Error),
        ];
        let mut breakers = BreakerRegistry::new();
        let out = settle_items(&plan, &outcomes, &mut breakers, &CircuitConfig::default(), 1000);
        assert_eq!(out.items, vec!["a1", "a2", "z1"]); // alpha before zeta (sorted-id merge)
        assert_eq!(out.survivors, vec!["alpha", "zeta"]);
        assert_eq!(out.failed.len(), 1);
        assert_eq!(out.failed[0].addon_id, "down");
    }
}
