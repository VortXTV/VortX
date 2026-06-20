//! Signed cache facts and their CRDT merge.
//!
//! A [`CacheFact`] is a node's signed claim about whether an infohash is cached on a debrid service. A
//! `cached: false` fact is a first-class signed NEGATIVE ("I checked; NOT cached"), the signal a cache
//! network must propagate as fast as a positive, not a deletion. Signatures cover a fixed canonical byte
//! string (see [`signing_bytes_for`]) so every platform's signature is byte-identical.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::hive_constants::{CACHEFACT_PREFIX, MAX_CLOCK_SKEW_SECS};
use crate::identity::{verify, NodeIdentity};
use crate::HiveError;

/// A debrid service a fact can be about. Wire strings match the ecosystem's ids. `dmm_public` is the
/// advisory bulk-import tier (DMM / Zilean / MediaFusion public hashlists), never authoritative.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum DebridService {
    #[serde(rename = "realdebrid")]
    RealDebrid,
    #[serde(rename = "alldebrid")]
    AllDebrid,
    #[serde(rename = "premiumize")]
    Premiumize,
    #[serde(rename = "torbox")]
    TorBox,
    #[serde(rename = "debridlink")]
    DebridLink,
    #[serde(rename = "easydebrid")]
    EasyDebrid,
    #[serde(rename = "dmm_public")]
    DmmPublic,
}

impl DebridService {
    /// The canonical wire token used in storage, URLs, and the signing payload.
    pub fn as_wire(&self) -> &'static str {
        match self {
            DebridService::RealDebrid => "realdebrid",
            DebridService::AllDebrid => "alldebrid",
            DebridService::Premiumize => "premiumize",
            DebridService::TorBox => "torbox",
            DebridService::DebridLink => "debridlink",
            DebridService::EasyDebrid => "easydebrid",
            DebridService::DmmPublic => "dmm_public",
        }
    }
}

/// A signed claim that `infohash` is (or is not) cached on `service`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CacheFact {
    /// Schema version; reject unknown major versions.
    #[serde(rename = "v")]
    pub version: u8,
    /// 40-char lowercase hex btih, normalized on construction.
    pub infohash: String,
    pub service: DebridService,
    /// The claim. `false` is a signed negative, not a deletion.
    pub cached: bool,
    /// File index inside a multi-file torrent; `None` = the whole-torrent claim (`-1` on the wire).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quality: Option<String>,
    /// Unix seconds; both the LWW clock and the freshness clock.
    pub verified_at: u64,
    /// Seconds; the fact is dead at `verified_at + ttl`.
    pub ttl: u64,
    /// base64url of the signer's 32-byte ed25519 public key.
    pub signer_pubkey: String,
    /// base64url of the 64-byte detached signature over [`signing_bytes_for`].
    pub sig: String,
}

/// The merge key: a fact is about exactly one (infohash, service, file slot). A file-level claim never
/// collides with the whole-torrent claim (`-1`).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CacheKey {
    pub infohash: String,
    pub service: DebridService,
    /// File index, or `-1` for the whole-torrent claim.
    pub file_idx: i64,
}

/// The merged hive cache map: the single latest fact per [`CacheKey`].
pub type HiveCacheMap = HashMap<CacheKey, CacheFact>;

/// Validate and normalize an infohash to 40 lowercase hex chars.
pub fn normalize_infohash(raw: &str) -> Result<String, HiveError> {
    let lowered = raw.trim().to_ascii_lowercase();
    if lowered.len() == 40 && lowered.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(lowered)
    } else {
        Err(HiveError::MalformedInfohash)
    }
}

/// Build the exact bytes a `CacheFact` signature covers:
///
/// ```text
/// b"vortx-cachefact-v1\n" + infohash|service|cached(1/0)|file_idx(-1 if none)|
///                           size(""if none)|quality(""if none)|verified_at|ttl|signer_pubkey
/// ```
///
/// Integers are decimal with no padding; absent optionals are empty strings. This is the cross-platform
/// interop anchor: any client that builds these bytes the same way produces the same signature.
#[allow(clippy::too_many_arguments)]
pub fn signing_bytes_for(
    infohash: &str,
    service: DebridService,
    cached: bool,
    file_idx: Option<u32>,
    size: Option<u64>,
    quality: Option<&str>,
    verified_at: u64,
    ttl: u64,
    signer_pubkey: &str,
) -> Vec<u8> {
    let canonical = format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}",
        infohash,
        service.as_wire(),
        if cached { "1" } else { "0" },
        file_idx
            .map(|x| x.to_string())
            .unwrap_or_else(|| "-1".to_string()),
        size.map(|x| x.to_string()).unwrap_or_default(),
        quality.unwrap_or(""),
        verified_at,
        ttl,
        signer_pubkey,
    );
    let mut out = Vec::with_capacity(CACHEFACT_PREFIX.len() + canonical.len());
    out.extend_from_slice(CACHEFACT_PREFIX);
    out.extend_from_slice(canonical.as_bytes());
    out
}

impl CacheFact {
    /// Construct and sign a fact with `identity`. Normalizes the infohash; the signature covers the
    /// canonical bytes, never the serialized JSON.
    #[allow(clippy::too_many_arguments)]
    pub fn create(
        identity: &NodeIdentity,
        infohash: &str,
        service: DebridService,
        cached: bool,
        file_idx: Option<u32>,
        size: Option<u64>,
        quality: Option<String>,
        verified_at: u64,
        ttl: u64,
    ) -> Result<Self, HiveError> {
        let infohash = normalize_infohash(infohash)?;
        let signer_pubkey = identity.public_b64url();
        let bytes = signing_bytes_for(
            &infohash,
            service,
            cached,
            file_idx,
            size,
            quality.as_deref(),
            verified_at,
            ttl,
            &signer_pubkey,
        );
        let sig = identity.sign(&bytes);
        Ok(Self {
            version: 1,
            infohash,
            service,
            cached,
            file_idx,
            size,
            quality,
            verified_at,
            ttl,
            signer_pubkey,
            sig,
        })
    }

    /// The canonical bytes this fact's signature must cover.
    pub fn signing_bytes(&self) -> Vec<u8> {
        signing_bytes_for(
            &self.infohash,
            self.service,
            self.cached,
            self.file_idx,
            self.size,
            self.quality.as_deref(),
            self.verified_at,
            self.ttl,
            &self.signer_pubkey,
        )
    }

    /// Verify the fact's ed25519 signature against its own `signer_pubkey`.
    pub fn verify_signed(&self) -> Result<(), HiveError> {
        verify(&self.signer_pubkey, &self.signing_bytes(), &self.sig)
    }

    /// Whether this fact is past `verified_at + ttl` at `now` (unix seconds).
    pub fn is_expired(&self, now: u64) -> bool {
        self.verified_at.saturating_add(self.ttl) < now
    }

    /// The merge key for this fact.
    pub fn key(&self) -> CacheKey {
        CacheKey {
            infohash: self.infohash.clone(),
            service: self.service,
            file_idx: self.file_idx.map(i64::from).unwrap_or(-1),
        }
    }
}

/// Merge one incoming fact into the map (the state-based delta-CRDT step). Returns `true` if it updated
/// the map's state. Drops (returns `false`, no state change) a fact that fails signature verification,
/// is dated beyond the clock-skew guard, or has already expired. State rule: newest `verified_at` wins;
/// on a tie, the lexicographically greater `signer_pubkey` wins (deterministic). The merge is
/// commutative, associative, and idempotent, so it converges regardless of gossip order or duplicates.
pub fn merge_fact(map: &mut HiveCacheMap, incoming: CacheFact, now: u64) -> bool {
    if incoming.verify_signed().is_err() {
        return false;
    }
    if incoming.verified_at > now.saturating_add(MAX_CLOCK_SKEW_SECS) {
        return false;
    }
    if incoming.is_expired(now) {
        return false;
    }
    let key = incoming.key();
    match map.get(&key) {
        None => {
            map.insert(key, incoming);
            true
        }
        Some(cur) => {
            let wins = incoming.verified_at > cur.verified_at
                || (incoming.verified_at == cur.verified_at
                    && incoming.signer_pubkey > cur.signer_pubkey);
            if wins {
                map.insert(key, incoming);
                true
            } else {
                false
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

    fn fact(id: &NodeIdentity, cached: bool, verified_at: u64) -> CacheFact {
        CacheFact::create(
            id,
            IH,
            DebridService::RealDebrid,
            cached,
            Some(3),
            Some(2_147_483_648),
            Some("1080p".into()),
            verified_at,
            86_400,
        )
        .unwrap()
    }

    #[test]
    fn canonical_bytes_are_frozen() {
        // The single most important interop test: pin the exact signed byte string.
        let bytes = signing_bytes_for(
            IH,
            DebridService::RealDebrid,
            true,
            Some(3),
            Some(2_147_483_648),
            Some("1080p"),
            1_718_900_000,
            86_400,
            "PUBKEY",
        );
        let expected =
            b"vortx-cachefact-v1\naabbccddeeff00112233445566778899aabbccdd|realdebrid|1|3|2147483648|1080p|1718900000|86400|PUBKEY";
        assert_eq!(bytes, expected);
    }

    #[test]
    fn canonical_bytes_use_sentinels_for_absent_optionals() {
        let bytes = signing_bytes_for(
            IH,
            DebridService::TorBox,
            false,
            None,
            None,
            None,
            10,
            20,
            "K",
        );
        let expected =
            b"vortx-cachefact-v1\naabbccddeeff00112233445566778899aabbccdd|torbox|0|-1|||10|20|K";
        assert_eq!(bytes, expected);
    }

    #[test]
    fn sign_then_verify_fact() {
        let id = NodeIdentity::generate().unwrap();
        let f = fact(&id, true, 1000);
        assert!(f.verify_signed().is_ok());
    }

    #[test]
    fn tampered_fact_fails_verify() {
        let id = NodeIdentity::generate().unwrap();
        let mut f = fact(&id, true, 1000);
        f.cached = false; // flip the claim without re-signing
        assert!(f.verify_signed().is_err());
    }

    #[test]
    fn malformed_infohash_is_rejected() {
        let id = NodeIdentity::generate().unwrap();
        let r = CacheFact::create(
            &id,
            "not-a-hash",
            DebridService::RealDebrid,
            true,
            None,
            None,
            None,
            1,
            1,
        );
        assert!(matches!(r, Err(HiveError::MalformedInfohash)));
    }

    #[test]
    fn debrid_service_round_trips_wire_strings() {
        let j = serde_json::to_string(&DebridService::DmmPublic).unwrap();
        assert_eq!(j, "\"dmm_public\"");
        let back: DebridService = serde_json::from_str("\"realdebrid\"").unwrap();
        assert_eq!(back, DebridService::RealDebrid);
    }

    #[test]
    fn expired_fact_is_ignored_on_merge() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let f = fact(&id, true, 1000); // ttl 86400 -> dead at 87400
        assert!(!merge_fact(&mut map, f, 200_000));
        assert!(map.is_empty());
    }

    #[test]
    fn future_fact_beyond_skew_is_dropped() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let f = fact(&id, true, 1_000_000);
        // now is well before verified_at, beyond the 300s skew guard.
        assert!(!merge_fact(&mut map, f, 1000));
        assert!(map.is_empty());
    }

    #[test]
    fn lww_newer_verified_at_wins() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let now = 5000;
        assert!(merge_fact(&mut map, fact(&id, true, 1000), now));
        assert!(merge_fact(&mut map, fact(&id, false, 2000), now)); // newer negative supersedes
        let key = CacheKey {
            infohash: IH.into(),
            service: DebridService::RealDebrid,
            file_idx: 3,
        };
        assert!(!map.get(&key).unwrap().cached);
    }

    #[test]
    fn tombstone_supersedes_stale_positive() {
        // A newer cached:false (negative) must win over an older cached:true.
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let now = 5000;
        merge_fact(&mut map, fact(&id, false, 3000), now);
        // older positive should NOT override the newer negative
        assert!(!merge_fact(&mut map, fact(&id, true, 1000), now));
        let key = CacheKey {
            infohash: IH.into(),
            service: DebridService::RealDebrid,
            file_idx: 3,
        };
        assert!(!map.get(&key).unwrap().cached);
    }

    #[test]
    fn file_idx_keys_do_not_collide_with_whole_torrent() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let now = 5000;
        let file = CacheFact::create(
            &id,
            IH,
            DebridService::RealDebrid,
            true,
            Some(2),
            None,
            None,
            1000,
            86_400,
        )
        .unwrap();
        let whole = CacheFact::create(
            &id,
            IH,
            DebridService::RealDebrid,
            true,
            None,
            None,
            None,
            1000,
            86_400,
        )
        .unwrap();
        assert!(merge_fact(&mut map, file, now));
        assert!(merge_fact(&mut map, whole, now));
        assert_eq!(map.len(), 2); // distinct keys: file_idx 2 and -1
    }

    #[test]
    fn merge_is_idempotent() {
        let id = NodeIdentity::generate().unwrap();
        let mut map = HiveCacheMap::new();
        let now = 5000;
        let f = fact(&id, true, 1000);
        assert!(merge_fact(&mut map, f.clone(), now));
        assert!(!merge_fact(&mut map, f, now)); // same fact again is a no-op
        assert_eq!(map.len(), 1);
    }

    #[test]
    fn merge_is_commutative_for_same_key() {
        let id = NodeIdentity::generate().unwrap();
        let now = 5000;
        let older = fact(&id, true, 1000);
        let newer = fact(&id, false, 2000);

        let mut a = HiveCacheMap::new();
        merge_fact(&mut a, older.clone(), now);
        merge_fact(&mut a, newer.clone(), now);

        let mut b = HiveCacheMap::new();
        merge_fact(&mut b, newer, now);
        merge_fact(&mut b, older, now);

        assert_eq!(a, b); // newest wins regardless of order
    }
}
