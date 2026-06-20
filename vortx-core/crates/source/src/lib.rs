//! # vortx-source
//!
//! The universal addon system. Every source family, Stremio addons (via `vortx-addons`), Nuvio providers
//! and Eclipse music (via `vortx-adapters`), ratings overlays (XRDB), scrapers, debrid stores, and
//! federated peers, becomes a `kind` behind ONE [`Source`] trait, registered in one [`SourceRegistry`].
//! On top of that sits the NATIVE [`VortxAddonManifest`] (`vortx-source/1`): a strict superset of the
//! Stremio manifest that adds what the one-shot JSON protocol structurally cannot express, streaming
//! results, prefetch hints, debrid-awareness (results flow into the hive vault), hive-awareness (signed
//! cache facts), per-profile config, declared permissions, and an ed25519 signature.
//!
//! Existing ecosystems plug in unchanged as `kind = stremio-addon` / `nuvio-provider`; the native format
//! opts into the engine's privileged hooks field by field. This crate is pure: `supports()` is a cheap
//! capability/id-space gate with no network, and `resolve()` is the only I/O point (deferred to the
//! engine phase here). Nothing in the shipping engine is touched.

mod adapters;
mod manifest;
mod registry;
mod request;
mod source;

pub use adapters::{NuvioProviderSource, StremioAddonSource};
pub use manifest::{
    ConfigCapability, DebridCapability, HiveCapability, ManifestSignature, RankingCapability,
    VortxAddonManifest, VortxTransport, NATIVE_SCHEMA,
};
pub use registry::SourceRegistry;
pub use request::{ResourceKind, ResourceRequest};
pub use source::{Source, SourceKind};

/// Errors a [`Source`] can return. `resolve` MUST NOT panic; it returns one of these (the orchestrator
/// treats any error as an empty result so one bad source never poisons a fan-out).
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SourceError {
    /// Real resolution happens in the engine I/O phase; the pure adapters return this.
    #[error("not implemented in the pure layer (resolution happens in the engine I/O phase)")]
    NotImplemented,
    #[error("network error: {0}")]
    Network(String),
    #[error("decode error: {0}")]
    Decode(String),
    #[error("source does not support this request")]
    Unsupported,
}
