//! The unified Source trait and its kinds. Every source family implements this; the registry only ever
//! sees `dyn Source`.

use serde::{Deserialize, Serialize};
use vortx_protocol::Stream;

use crate::request::{ResourceKind, ResourceRequest};
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

    /// Resolve `req` to streams. The only I/O point. MUST NOT panic; on failure returns an error (the
    /// orchestrator treats it as empty so one bad source never poisons the fan-out). In this pure crate
    /// the wrappers return [`SourceError::NotImplemented`]; real resolution lands in the engine phase.
    fn resolve(&self, req: &ResourceRequest) -> Result<Vec<Stream>, SourceError>;
}
