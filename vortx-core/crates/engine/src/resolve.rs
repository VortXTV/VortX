//! Resource resolution: the QUERY half of the engine, parallel to the command half (`dispatch`). A
//! command mutates profile state and returns events; a query is read-only and returns a DECISION the host
//! acts on. They are deliberately separate paths so the FFI surface stays a clean command/query split.
//!
//! The engine never does I/O. The host (which owns the network) fetches an addon's raw results and hands
//! them in; the engine routes them through the pure kernel crates and returns the typed decision. For
//! streams that decision is the ranked, player-ready order from `vortx-ranking` (fixed-point, so the
//! ranking is byte-reproducible across the Swift, Kotlin, and TS bridges that call this).

use serde::{Deserialize, Serialize};
use vortx_debrid::{
    DebridService, ResolvePlanner, ResolveSource, ResolveStep, StaticCacheView,
};
use vortx_protocol::{MetaDetail, MetaPreview, Stream};
use vortx_ranking::{rank, RankedStream, RankingPrefs};
use vortx_reco::visible_catalog;
use vortx_state::maturity_allows_raw;
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
}

/// The engine's decision for a resolution request. Tagged by `kind`; an `error` variant keeps the host's
/// JSON parse total (a bad request never produces unparseable output).
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResolveResponse {
    Streams { ranked: Vec<RankedStream> },
    /// The chosen subtitle track, or `null` when nothing was eligible.
    Subtitles { selected: Option<SubtitleSelection> },
    /// The catalog rows the active profile is allowed to see.
    Catalog { metas: Vec<MetaPreview> },
    /// The meta detail, or `null` when the active profile's parental controls block it.
    Meta { meta: Option<Box<MetaDetail>> },
    /// The ordered resolve plan (rank 0 = try first).
    Debrid { plan: Vec<ResolveStep> },
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
        } => {
            // Explicit prefs win; otherwise fall back to the active profile's stored ranking prefs.
            let prefs = prefs.unwrap_or_else(|| {
                engine
                    .store()
                    .active_profile()
                    .map(|p| p.settings.ranking.clone())
                    .unwrap_or_default()
            });
            ResolveResponse::Streams {
                ranked: rank(&streams, &prefs, &cached),
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
        };
        let ResolveResponse::Streams { ranked } = resolve(&engine, req) else {
            panic!("expected streams response");
        };
        assert_eq!(ranked[0].raw_index, 1); // 2160p outranks 1080p
        assert!(ranked[0].score > ranked[1].score);
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
