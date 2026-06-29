//! The unified Source trait and its kinds. Every source family implements this; the registry only ever
//! sees `dyn Source`.

use serde::{Deserialize, Serialize};
use vortx_protocol::Stream;

use crate::request::{ResourceKind, ResourceRequest};
use crate::transport::FetchRequest;
use crate::SourceError;

/// What kind of source this is. Existing ecosystems are wrapped as a kind; `NativeVortx` implements the
/// trait directly with the engine's privileged hooks turned on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    StremioAddon,
    NuvioProvider,
    NativeVortx,
    Ratings,
    Scraper,
    DebridStore,
    Federated,
    Music,
    /// A live TV source family (M3U playlists + XMLTV/EPG): live channels + programme guide.
    Iptv,
}

/// One source of catalogs / meta / streams / ratings / etc. The orchestrator queries every matching
/// source and fuses the results.
pub trait Source {
    /// A stable id, unique within a registry (e.g. the transport URL or provider id).
    fn id(&self) -> &str;

    /// The source kind.
    fn kind(&self) -> SourceKind;

    /// The resources this source can serve.
    fn capabilities(&self) -> &[ResourceKind];

    /// Whether this source can answer `req`. Cheap, synchronous, id-space gated; performs NO network.
    fn supports(&self, req: &ResourceRequest) -> bool;

    /// Plan the host fetch this source would issue for `req`, or `None` if it cannot answer over the
    /// simple request/response transport (a local-only source, or one whose I/O path is not yet wired).
    /// PURE: it builds the [`FetchRequest`] (addon id + URL + budget), it does NOT perform the fetch.
    /// The orchestrator drives every source's plan through the host [`crate::Fetch`] boundary, so this is
    /// the per-source half of the deadline-bounded fan-out. Default: `None` (the source does no network).
    fn plan(&self, _req: &ResourceRequest, _budget_ms: u64) -> Option<FetchRequest> {
        None
    }

    /// Resolve `req` to streams. The only I/O point. MUST NOT panic; on failure returns an error (the
    /// orchestrator treats it as empty so one bad source never poisons the fan-out). In this pure crate
    /// the wrappers return [`SourceError::NotImplemented`]; real resolution drives [`plan`](Source::plan)
    /// through the host fetch boundary in [`crate::resolve_streams`] instead of blocking here.
    fn resolve(&self, req: &ResourceRequest) -> Result<Vec<Stream>, SourceError>;
}
