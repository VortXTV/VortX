//! # vortx-debrid
//!
//! The debrid layer, modelled on StremThru's normalized Store so RealDebrid, AllDebrid, Premiumize,
//! TorBox and friends all sit behind ONE [`DebridStore`] trait instead of N bespoke integrations. stremio
//! -core has no debrid concept at all (debrid only ever arrives through a third-party add-on); VortX owns
//! it natively. This crate is pure (no HTTP, no async): the trait + normalized types + a per-profile
//! credential format + a resolve-order planner that reuses the [`vortx_hive`] CacheFact vault as a
//! cross-node cache map. Real store HTTP clients and the torrent engine are later phases.
//!
//! Load-bearing rule: share facts, never tokens. The vault tells us an infohash is cached on a service;
//! the playable link is always re-minted locally with the user's OWN credential.

mod credential;
mod resolve;
mod store;

pub use credential::parse_credential;
pub use resolve::{
    CacheView, ResolveMethod, ResolvePlanner, ResolveSource, ResolveStep, StaticCacheView,
    VaultCacheView,
};
pub use store::{
    check_magnets_batched, AddedMagnet, DebridStore, DebridUser, MagnetFile, MagnetInfo,
    MagnetStatus, CHECK_BATCH_SIZE,
};
pub use vortx_hive::DebridService;

/// Errors from a debrid store operation.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum DebridError {
    #[error("unauthorized (bad or expired api key)")]
    Unauthorized,
    #[error("not found")]
    NotFound,
    #[error("rate limited")]
    RateLimited,
    #[error("debrid error: {0}")]
    Other(String),
}
