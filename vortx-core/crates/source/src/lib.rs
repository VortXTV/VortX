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
mod cached;
mod canonical;
mod customization;
mod entry;
mod exit;
mod fanout;
mod identity;
mod manifest;
mod native;
mod orchestrate;
mod pagination;
mod registry;
mod request;
mod source;
mod transport;
mod validate;
mod verify;

pub use adapters::{NuvioProviderSource, StremioAddonSource};
pub use cached::{cached_on, cached_vector, stream_is_cached};
pub use canonical::canonicalize;
pub use customization::{
    token_keys, AccentDef, AssetRef, BrandingDef, Color, CustomizationCapability, HeroDecl,
    HomeLayout, LayoutDef, MotionDef, PaletteOverride, RadiusDef, RailDecl, Splash, TabDecl,
    ThemeDef, Wordmark,
};
pub use entry::{plan_streams, SourceEntry};
pub use exit::{should_stop, ExitConfig, ExitDecision, ExitReason, PartialResult};
pub use fanout::{
    aggregate, AddonResult, Aggregate, BreakerRegistry, BreakerState, CircuitBreaker,
    CircuitConfig, FailedAddon, FailureKind, Outcome,
};
pub use identity::{reconcile, CanonicalId, ExternalId, IdSet, Namespace};
pub use manifest::{
    ConfigCapability, DebridCapability, HiveCapability, ManifestSignature, RankingCapability,
    VortxAddonManifest, VortxTransport, NATIVE_SCHEMA,
};
pub use native::NativeVortxSource;
pub use orchestrate::{parse_stream_item, resolve_streams, settle_streams, ResolvedStreams};
pub use pagination::{next_page, AddonPage, CatalogCursor, Page};
pub use registry::SourceRegistry;
pub use request::{EpgWindow, ResourceKind, ResourceRequest};
pub use source::{Source, SourceKind};
pub use transport::{
    execute_plan, plan_fanout, run_fanout, settle_fanout, Fetch, FetchOutcome, FetchRequest,
};
pub use validate::{has_errors, validate, Issue, Severity};
pub use verify::{manifest_signing_bytes, verify_manifest, ManifestVerification};

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
