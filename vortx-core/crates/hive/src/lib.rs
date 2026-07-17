//! # vortx-hive
//!
//! The VortX federation/hive public-plane data model. Self-hosted VortX nodes form a hive that shares
//! FACTS about sources, never about people: a debrid cache map, a federated torrent index, live health.
//! This crate is the pure, portable core of that plane:
//!
//! - [`NodeIdentity`] : an ed25519 keypair; one per node. The node id is `base64url(SHA-256(pubkey)[..16])`.
//! - [`CacheFact`] : a signed claim "infohash X is/ISN'T cached on debrid service Y". Signatures cover a
//!   FIXED canonical byte string (not serialized JSON), so Swift/Go/JS/Rust all produce identical bytes.
//! - [`merge_fact`] : the state-based delta-CRDT merge (LWW by `verified_at` + TTL + clock-skew guard),
//!   commutative/associative/idempotent so it converges regardless of gossip order or duplicates.
//! - [`TrustStore`] : the trust tiers (own > trusted-allowlist > public) and the load-bearing invariant
//!   that a cache claim is actionable only after the node's OWN debrid confirms OR >= 3 independent
//!   trusted signers confirm. A lying peer can waste one re-check but cannot poison playback.
//!
//! Hard rule: share facts, never tokens. A `CacheFact` carries an infohash + a cached boolean, never a
//! resolved, token-bound link. The playable URL is always re-minted locally with the user's own debrid
//! token. The private per-profile sync plane (the shipped Cloudflare E2E backup) is a SEPARATE plane and
//! is never read by, mixed with, or exposed through anything here.
//!
//! This crate is intentionally pure: no networking, no async, no FFI. The `/hive/*` HTTP client, the
//! `FederatedAdapter` Source, and the Cloudflare corpus mirror are later (0.4.0+) phases that build on
//! these frozen, tested types.

mod covisit;
mod fact;
mod identity;
mod trust;

pub use covisit::{
    authoritative_covisit_strength, covisit_signing_bytes_for, merge_covisit, pair_facts,
    CoVisitFact, CoVisitKey, CoVisitMap,
};
pub use fact::{
    merge_fact, normalize_infohash, signing_bytes_for, CacheFact, CacheKey, DebridService,
    HiveCacheMap,
};
pub use identity::{
    node_id_from_pubkey_b64, node_id_from_pubkey_bytes, verify, NodeId, NodeIdentity, SignerPubkey,
};
pub use trust::{TrustStore, TrustTier};

/// Errors from hive data-model operations (signing, verification, validation).
#[derive(Debug, thiserror::Error)]
pub enum HiveError {
    #[error("bad signature")]
    BadSignature,
    #[error("fact has expired")]
    Expired,
    #[error("fact timestamp is too far in the future")]
    FutureFact,
    #[error("malformed infohash (want 40 lowercase hex chars)")]
    MalformedInfohash,
    #[error("malformed quality tag (no '|' or control chars, max 16 chars)")]
    MalformedQuality,
    #[error("malformed item id (non-empty, no '|' or control chars, max 128 chars)")]
    MalformedItemId,
    #[error("unknown debrid service")]
    UnknownService,
    #[error("base64url decode error")]
    Base64,
    #[error("invalid key or signature length")]
    Key,
}

/// Locked constants for the hive plane (signing prefixes, CRDT/trust bounds).
pub mod hive_constants {
    /// Domain-separation prefix for a `CacheFact` signature (sign bytes, not JSON).
    pub const CACHEFACT_PREFIX: &[u8] = b"vortx-cachefact-v1\n";
    /// Domain-separation prefix for a federated torrent-index entry signature.
    pub const TORRENTINDEX_PREFIX: &[u8] = b"vortx-torrentindex-v1\n";
    /// Domain-separation prefix for a playback-asset availability fact signature (trickplay sprite /
    /// skip markers / chapters). Lives beside the others so every signing prefix is frozen in one place.
    pub const ASSETFACT_PREFIX: &[u8] = b"vortx-assetfact-v1\n";
    /// Domain-separation prefix for an item-item co-visit fact signature (collaborative-filtering plane).
    pub const COVISIT_PREFIX: &[u8] = b"vortx-covisit-v1\n";
    /// A single co-visit fact's count is capped, so one signer cannot claim an outsized co-occurrence to
    /// dominate the tally; authority still comes from quorum, not raw magnitude.
    pub const COVISIT_COUNT_CAP: u32 = 1_000;
    /// Reject facts dated more than this far in the future (clock-skew guard), seconds.
    pub const MAX_CLOCK_SKEW_SECS: u64 = 300;
    /// Public-tier facts are capped to this TTL regardless of their stated `ttl`, seconds.
    pub const PUBLIC_TTL_CAP_SECS: u64 = 6 * 3600;
    /// Distinct trusted signers required to make a cache claim actionable (besides own-debrid).
    pub const QUORUM_N: usize = 3;
    /// Reputation EWMA: agreement gain factor.
    pub const REP_ALPHA: f64 = 0.2;
    /// Reputation EWMA: disagreement loss factor (harsh).
    pub const REP_BETA: f64 = 0.5;
    /// Below this reputation a signer is greylisted and contributes 0 to quorum.
    pub const REP_GREYLIST_THRESHOLD: f64 = 0.1;
    /// How long a greylist lasts, seconds.
    pub const REP_GREYLIST_SECS: u64 = 24 * 3600;
    /// Reputation a never-before-seen signer starts at (neutral).
    pub const REP_DEFAULT: f64 = 0.5;
}
