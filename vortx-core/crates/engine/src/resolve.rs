//! Resource resolution: the QUERY half of the engine, parallel to the command half (`dispatch`). A
//! command mutates profile state and returns events; a query is read-only and returns a DECISION the host
//! acts on. They are deliberately separate paths so the FFI surface stays a clean command/query split.
//!
//! The engine never does I/O. The host (which owns the network) fetches an addon's raw results and hands
//! them in; the engine routes them through the pure kernel crates and returns the typed decision. For
//! streams that decision is the ranked, player-ready order from `vortx-ranking` (fixed-point, so the
//! ranking is byte-reproducible across the Swift, Kotlin, and TS bridges that call this).

use std::collections::{BTreeMap, HashMap};

use serde::{Deserialize, Serialize};
use vortx_debrid::{
    DebridService, ResolvePlanner, ResolveSource, ResolveStep, StaticCacheView,
};
use vortx_protocol::{ContentKind, MetaDetail, MetaPreview, Stream};
use vortx_ranking::{rank, rank_for, RankedStream, RankingPrefs};
use vortx_reco::{
    build_home_feed, build_taste, visible_catalog, watch_log_from_library, AllEligible, AllOf,
    AvailabilitySet, EligibilityFilter, HomeFeedInput, HomeFeedPrefs, Lane, MaturityGate,
};
use vortx_source::{
    cached_vector, plan_streams, settle_catalog, settle_streams, BreakerRegistry, CircuitConfig,
    FetchOutcome, FetchRequest, ResourceRequest, SourceEntry,
};
use vortx_state::{maturity_allows_raw, parse_certification, MaturityRating};
use vortx_subtitles::{select as select_subtitle, SubtitlePrefs, SubtitleSelection, SubtitleTrack};

use crate::engine::Engine;

/// A `(infohash, service)` pair the host already knows is cached (read from its hive vault), supplied so
/// the engine can plan a debrid resolve without doing any I/O of its own.
#[derive(Debug, Clone, Deserialize)]
pub struct CachedEntry {
    pub infohash: String,
    pub service: DebridService,
}

/// A resolution request from the host. Tagged by `kind` (snake_case). More resources (catalog / meta /
/// subtitles) join here as their pure pipelines are wired; streams is the player-critical first path.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResolveRequest {
    /// Decide the play order for already-fetched streams. `cached[i]` marks stream `i` debrid-cached (a
    /// missing entry is treated as not cached). `prefs` are the active profile's ranking preferences.
    Streams {
        streams: Vec<Stream>,
        #[serde(default)]
        cached: Vec<bool>,
        /// Explicit ranking prefs. When omitted, the ACTIVE profile's stored prefs are used, so a profile
        /// that set its preferences once gets them applied to every stream resolve without re-sending them.
        #[serde(default)]
        prefs: Option<RankingPrefs>,
        /// The content kind, so the engine selects the per-kind ranking profile. Omitted = the frozen video
        /// profile (byte-identical to the prior behavior), so existing requests rank unchanged.
        #[serde(default, rename = "contentKind", skip_serializing_if = "Option::is_none")]
        content_kind: Option<ContentKind>,
    },
    /// PLAN phase of a stream LOAD: given a snapshot of the host's installed sources + their circuit
    /// breakers, decide WHICH to query and return the deadline-stamped fetch requests (circuit-open sources
    /// skipped, sorted by addon id). The engine holds no source state of its own, so the request carries the
    /// snapshots + the host clock (`now`); the kernel stays pure and clockless. The host realizes the plan
    /// through its Fetch boundary, then settles it (the settle phase, host-side, updates the breakers). This
    /// is the stateless half of the LOAD effect model.
    StreamLoad {
        req: ResourceRequest,
        #[serde(default, rename = "registrySnapshot")]
        registry_snapshot: Vec<SourceEntry>,
        #[serde(default, rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
        #[serde(default, rename = "circuitCfg")]
        circuit_cfg: CircuitConfig,
        #[serde(default)]
        now: u64,
        #[serde(default = "default_budget_ms", rename = "budgetMs")]
        budget_ms: u64,
    },
    /// SETTLE phase of a stream LOAD: the host realized the plan through its Fetch boundary and hands back the
    /// per-source outcomes. The engine settles them (a missing outcome = Timeout; failures isolated), parses
    /// the merged items into streams, and ranks them with the cached-availability vector + the active
    /// profile's prefs. PURE over the breaker snapshot: it comes in, is updated on a local copy, and is
    /// returned for the host to upsert; the kernel holds no breaker state.
    SettleStreams {
        plan: Vec<FetchRequest>,
        /// Per-source outcomes the host fetched, keyed by addon id. A planned source missing here settles as
        /// Timeout (partial-result settlement).
        #[serde(default)]
        outcomes: BTreeMap<String, FetchOutcome>,
        #[serde(default, rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
        #[serde(default, rename = "circuitCfg")]
        circuit_cfg: CircuitConfig,
        #[serde(default)]
        now: u64,
        /// The user's enabled debrid services, used to mark a stream cached (from its typed cachedServices).
        #[serde(default, rename = "userServices")]
        user_services: Vec<DebridService>,
        /// Explicit ranking prefs; when omitted, the active profile's stored prefs are used.
        #[serde(default)]
        prefs: Option<RankingPrefs>,
        /// The content kind for per-kind ranking-profile selection; omitted = the frozen video profile.
        #[serde(default, rename = "contentKind", skip_serializing_if = "Option::is_none")]
        content_kind: Option<ContentKind>,
    },
    /// PLAN phase of a CATALOG LOAD: the catalog twin of [`StreamLoad`]. Same stateless effect model and the
    /// SAME `plan_streams` planner (it routes by the request's `ResourceKind`, so a catalog request yields
    /// catalog fetch URLs); the engine holds no source state. The host realizes the plan, then settles it.
    CatalogLoad {
        req: ResourceRequest,
        #[serde(default, rename = "registrySnapshot")]
        registry_snapshot: Vec<SourceEntry>,
        #[serde(default, rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
        #[serde(default, rename = "circuitCfg")]
        circuit_cfg: CircuitConfig,
        #[serde(default)]
        now: u64,
        #[serde(default = "default_budget_ms", rename = "budgetMs")]
        budget_ms: u64,
    },
    /// SETTLE phase of a CATALOG LOAD: the host hands back the per-source outcomes; the engine settles them
    /// (missing -> Timeout, failures isolated), parses the merged items into catalog rows, and enforces the
    /// ACTIVE profile's parental controls (a kids profile never receives an over-ceiling/unrated row, the same
    /// gate as the one-shot `Catalog` query). PURE over the breaker snapshot (in -> updated copy -> out).
    SettleCatalog {
        plan: Vec<FetchRequest>,
        #[serde(default)]
        outcomes: BTreeMap<String, FetchOutcome>,
        #[serde(default, rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
        #[serde(default, rename = "circuitCfg")]
        circuit_cfg: CircuitConfig,
        #[serde(default)]
        now: u64,
    },
    /// Pick the best subtitle track from the host-provided candidates for the given preferences.
    Subtitles {
        tracks: Vec<SubtitleTrack>,
        #[serde(default)]
        prefs: SubtitlePrefs,
    },
    /// Filter a catalog page through the ACTIVE profile's parental controls before it is shown. A kids
    /// profile is enforced here, inside the engine, so a host cannot forget to gate a row.
    Catalog { metas: Vec<MetaPreview> },
    /// Gate a single meta detail (e.g. a deep link) through the active profile's parental controls.
    /// Boxed: `MetaDetail` is large, so this keeps the request enum small.
    Meta { meta: Box<MetaDetail> },
    /// Plan how to resolve a set of sources (direct / magnet) into a playable order: instant debrid-cached
    /// first, then an uncached debrid add, then P2P torrent. The host supplies the known-cached pairs and
    /// the user's services; the engine does no network.
    Debrid {
        sources: Vec<ResolveSource>,
        #[serde(default, rename = "userServices")]
        user_services: Vec<DebridService>,
        #[serde(default)]
        cached: Vec<CachedEntry>,
        #[serde(default)]
        now: u64,
    },
    /// Build the Home feed from the ACTIVE profile's library (continue-watching + history -> Up Next /
    /// Start Watching) plus a host popularity list, parental-enforced and availability-filtered THROUGH the
    /// engine. (The taste-based Because You Watched lane is a follow-up; it needs engagements wired.)
    HomeFeed {
        #[serde(default)]
        trending: Vec<String>,
        /// Available (playable) meta ids; `null`/absent = treat everything as available.
        #[serde(default)]
        available: Option<Vec<String>>,
        /// Per-meta certification for the parental gate.
        #[serde(default)]
        ratings: Vec<RatingEntry>,
    },
}

/// Default per-request fetch budget (ms) for a stream LOAD plan when the host omits it.
fn default_budget_ms() -> u64 {
    5000
}

/// A `(meta id, certification)` pair the host supplies so the engine can parental-gate Home feed lanes.
#[derive(Debug, Clone, Deserialize)]
pub struct RatingEntry {
    pub meta_id: String,
    #[serde(default)]
    pub certification: Option<String>,
}

/// The engine's decision for a resolution request. Tagged by `kind`; an `error` variant keeps the host's
/// JSON parse total (a bad request never produces unparseable output).
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResolveResponse {
    Streams { ranked: Vec<RankedStream> },
    /// The fetch plan for a stream LOAD: the deadline-stamped requests the host should perform (circuit-open
    /// sources skipped, sorted by addon id). The host fetches these, then settles via the host-side settle.
    StreamLoadPlan { requests: Vec<FetchRequest> },
    /// The settled stream LOAD: the ranked player-ready order, plus the updated circuit-breaker snapshot the
    /// host upserts (the engine holds no breaker state). Kept distinct from `Streams` so the host can pick up
    /// the breaker snapshot from the LOAD path without changing the one-shot rank response shape.
    SettledStreams {
        ranked: Vec<RankedStream>,
        #[serde(rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
    },
    /// The fetch plan for a catalog LOAD (circuit-open sources skipped, sorted by addon id).
    CatalogLoadPlan { requests: Vec<FetchRequest> },
    /// The settled catalog LOAD: the parental-filtered catalog rows + the updated breaker snapshot the host
    /// upserts. Distinct from `Catalog` (the one-shot filter of already-fetched rows) because the LOAD path
    /// also returns the breaker snapshot the host must persist.
    SettledCatalog {
        metas: Vec<MetaPreview>,
        #[serde(rename = "circuitSnapshot")]
        circuit_snapshot: BreakerRegistry,
    },
    /// The chosen subtitle track, or `null` when nothing was eligible.
    Subtitles { selected: Option<SubtitleSelection> },
    /// The catalog rows the active profile is allowed to see.
    Catalog { metas: Vec<MetaPreview> },
    /// The meta detail, or `null` when the active profile's parental controls block it.
    Meta { meta: Option<Box<MetaDetail>> },
    /// The ordered resolve plan (rank 0 = try first).
    Debrid { plan: Vec<ResolveStep> },
    /// The Home feed lanes (empty lanes dropped).
    HomeFeed { lanes: Vec<Lane> },
    Error { error: String },
}

/// Resolve one request against the engine. Pure: no I/O, no state mutation. `engine` is threaded for the
/// resources that will read profile state (catalog/home feed); the streams path is stateless given
/// explicit prefs.
pub fn resolve(engine: &Engine, req: ResolveRequest) -> ResolveResponse {
    match req {
        ResolveRequest::Streams {
            streams,
            cached,
            prefs,
            content_kind,
        } => {
            // Explicit prefs win; otherwise fall back to the active profile's stored ranking prefs.
            let prefs = prefs.unwrap_or_else(|| {
                engine
                    .store()
                    .active_profile()
                    .map(|p| p.settings.ranking.clone())
                    .unwrap_or_default()
            });
            // Select the per-kind ranking profile; omitted kind = the frozen video ranker (unchanged).
            let ranked = match content_kind {
                Some(k) => rank_for(k, &streams, &prefs, &cached),
                None => rank(&streams, &prefs, &cached),
            };
            ResolveResponse::Streams { ranked }
        }
        ResolveRequest::StreamLoad {
            req,
            registry_snapshot,
            circuit_snapshot,
            circuit_cfg,
            now,
            budget_ms,
        } => {
            // Pure stateless planning: route the request over the host's source snapshot and circuit-filter
            // it. The engine owns the WHICH/HOW decision; the host owns the bytes, the breaker state, and the
            // clock. No engine state is read or mutated.
            ResolveResponse::StreamLoadPlan {
                requests: plan_streams(
                    &registry_snapshot,
                    &req,
                    &circuit_snapshot,
                    &circuit_cfg,
                    now,
                    budget_ms,
                ),
            }
        }
        ResolveRequest::SettleStreams {
            plan,
            outcomes,
            mut circuit_snapshot,
            circuit_cfg,
            now,
            user_services,
            prefs,
            content_kind,
        } => {
            // Settle the host's outcomes into typed streams (failures isolated; missing -> Timeout), updating
            // the breaker snapshot on a LOCAL copy that is returned for the host to upsert. The engine holds
            // no breaker state, so this stays a pure (snapshot_in, outcomes) -> (ranked, snapshot_out) query.
            let outcomes: Vec<(String, FetchOutcome)> = outcomes.into_iter().collect();
            let resolved = settle_streams(
                &plan,
                &outcomes,
                &mut circuit_snapshot,
                &circuit_cfg,
                now,
            );
            // Mark cached from each stream's typed cachedServices vs the user's services, and rank with the
            // explicit prefs or the active profile's stored prefs.
            let cached = cached_vector(&resolved.streams, &user_services);
            let prefs = prefs.unwrap_or_else(|| {
                engine
                    .store()
                    .active_profile()
                    .map(|p| p.settings.ranking.clone())
                    .unwrap_or_default()
            });
            let ranked = match content_kind {
                Some(k) => rank_for(k, &resolved.streams, &prefs, &cached),
                None => rank(&resolved.streams, &prefs, &cached),
            };
            ResolveResponse::SettledStreams {
                ranked,
                circuit_snapshot,
            }
        }
        ResolveRequest::CatalogLoad {
            req,
            registry_snapshot,
            circuit_snapshot,
            circuit_cfg,
            now,
            budget_ms,
        } => {
            // The catalog twin of StreamLoad: the same pure stateless planner routes the catalog request over
            // the host source snapshot (plan_streams keys off req's ResourceKind), returning the fetch plan.
            ResolveResponse::CatalogLoadPlan {
                requests: plan_streams(
                    &registry_snapshot,
                    &req,
                    &circuit_snapshot,
                    &circuit_cfg,
                    now,
                    budget_ms,
                ),
            }
        }
        ResolveRequest::SettleCatalog {
            plan,
            outcomes,
            mut circuit_snapshot,
            circuit_cfg,
            now,
        } => {
            // Settle the catalog outcomes into rows (failures isolated; missing -> Timeout) on a LOCAL breaker
            // copy returned for the host to upsert, then enforce the active profile's parental controls (the
            // same gate as the one-shot Catalog query) so a kids profile never receives a blocked row.
            let outcomes: Vec<(String, FetchOutcome)> = outcomes.into_iter().collect();
            let resolved = settle_catalog(&plan, &outcomes, &mut circuit_snapshot, &circuit_cfg, now);
            let metas = match engine.store().active_profile() {
                Some(p) => visible_catalog(&resolved.metas, &p.parental)
                    .into_iter()
                    .cloned()
                    .collect(),
                None => resolved.metas,
            };
            ResolveResponse::SettledCatalog {
                metas,
                circuit_snapshot,
            }
        }
        ResolveRequest::Subtitles { tracks, prefs } => ResolveResponse::Subtitles {
            selected: select_subtitle(&tracks, &prefs),
        },
        ResolveRequest::Catalog { metas } => {
            // Enforce the active profile's parental controls inside the engine: a kids profile never even
            // receives an over-ceiling or unrated row.
            let visible = match engine.store().active_profile() {
                Some(p) => visible_catalog(&metas, &p.parental)
                    .into_iter()
                    .cloned()
                    .collect(),
                None => metas,
            };
            ResolveResponse::Catalog { metas: visible }
        }
        ResolveRequest::Meta { meta } => {
            // A blocked meta returns null, so a kids profile cannot open an over-ceiling title even via a
            // direct deep link, not just by browsing the catalog.
            let allowed = match engine.store().active_profile() {
                Some(p) => maturity_allows_raw(&p.parental, meta.certification.as_deref()),
                None => true,
            };
            ResolveResponse::Meta {
                meta: allowed.then_some(meta),
            }
        }
        ResolveRequest::Debrid {
            sources,
            user_services,
            cached,
            now,
        } => {
            let view = StaticCacheView::new(
                cached.into_iter().map(|c| (c.infohash, c.service)).collect(),
            );
            let plan = ResolvePlanner::new(user_services).plan(&sources, &view, now);
            ResolveResponse::Debrid { plan }
        }
        ResolveRequest::HomeFeed {
            trending,
            available,
            ratings,
        } => {
            // Everything the feed reads from the store: the active profile's parental flags, and a watch
            // log + saved-library list derived from its continue-watching / history.
            let flags = engine
                .store()
                .active_profile()
                .map(|p| p.parental.clone())
                .unwrap_or_default();
            let (watch_log, library_ids) = match engine.store().active_library() {
                Some(lib) => (
                    watch_log_from_library(lib),
                    lib.items.iter().map(|i| i.id().to_string()).collect::<Vec<_>>(),
                ),
                None => (Default::default(), Vec::new()),
            };
            let ratings_map: HashMap<String, Option<MaturityRating>> = ratings
                .into_iter()
                .map(|r| {
                    let rating = r.certification.as_deref().and_then(parse_certification);
                    (r.meta_id, rating)
                })
                .collect();
            let taste = build_taste(&[]);
            let input = HomeFeedInput {
                watch_log: &watch_log,
                library: &library_ids,
                candidates: &[],
                taste: &taste,
                trending: &trending,
            };
            // Parental controls AND availability are both enforced inside the engine.
            let gate = MaturityGate {
                flags: &flags,
                ratings: &ratings_map,
            };
            let avail: Box<dyn EligibilityFilter> = match available {
                Some(ids) => Box::new(AvailabilitySet::new(ids)),
                None => Box::new(AllEligible),
            };
            let filters: [&dyn EligibilityFilter; 2] = [avail.as_ref(), &gate];
            let feed = build_home_feed(&input, &AllOf(&filters), &HomeFeedPrefs::default());
            ResolveResponse::HomeFeed { lanes: feed.lanes }
        }
    }
}

/// The FFI query entry point: a JSON request string in, a JSON [`ResolveResponse`] string out. A malformed
/// request yields a well-formed `{ "kind": "error", ... }` rather than an error, so the host always gets
/// parseable JSON.
pub fn resolve_json(engine: &Engine, request_json: &str) -> String {
    let response = match serde_json::from_str::<ResolveRequest>(request_json) {
        Ok(req) => resolve(engine, req),
        Err(e) => ResolveResponse::Error {
            error: format!("bad request: {e}"),
        },
    };
    serde_json::to_string(&response).unwrap_or_else(|_| {
        r#"{"kind":"error","error":"serialize failed"}"#.to_string()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init_runtime;

    fn stream(label: &str) -> Stream {
        Stream {
            name: Some(label.into()),
            ..Default::default()
        }
    }

    #[test]
    fn resolves_streams_into_ranked_order() {
        let engine = init_runtime("owner", "Owner");
        let req = ResolveRequest::Streams {
            streams: vec![stream("1080p WEB-DL"), stream("2160p WEB-DL")],
            cached: vec![false, false],
            prefs: None, // falls back to the active (owner) profile's default prefs
            content_kind: None,
        };
        let ResolveResponse::Streams { ranked } = resolve(&engine, req) else {
            panic!("expected streams response");
        };
        assert_eq!(ranked[0].raw_index, 1); // 2160p outranks 1080p
        assert!(ranked[0].score > ranked[1].score);
    }

    #[test]
    fn content_kind_movie_ranks_identically_to_the_default() {
        // The per-kind selector: a movie (video class) ranks byte-identically to omitting the kind.
        let engine = init_runtime("owner", "Owner");
        let streams = vec![stream("1080p WEB-DL"), stream("2160p WEB-DL")];
        let with_kind = resolve(
            &engine,
            ResolveRequest::Streams {
                streams: streams.clone(),
                cached: vec![false, false],
                prefs: None,
                content_kind: Some(ContentKind::Movie),
            },
        );
        let without = resolve(
            &engine,
            ResolveRequest::Streams {
                streams,
                cached: vec![false, false],
                prefs: None,
                content_kind: None,
            },
        );
        let (ResolveResponse::Streams { ranked: a }, ResolveResponse::Streams { ranked: b }) =
            (with_kind, without)
        else {
            panic!("expected streams responses");
        };
        assert_eq!(a, b); // video profile == frozen default
    }

    #[test]
    fn resolve_json_round_trips_and_is_panic_free() {
        let engine = init_runtime("owner", "Owner");
        let out = resolve_json(
            &engine,
            r#"{"kind":"streams","streams":[{"name":"720p WEB-DL"}],"cached":[true]}"#,
        );
        assert!(out.contains("\"kind\":\"streams\""));
        // Malformed input stays parseable as an error.
        let bad = resolve_json(&engine, "not json");
        assert!(bad.contains("\"kind\":\"error\""));
    }
}
