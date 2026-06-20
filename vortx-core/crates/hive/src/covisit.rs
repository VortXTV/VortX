//! The collaborative-filtering plane: signed item-item co-visit facts, gossiped and trust-gated exactly
//! like [`crate::CacheFact`]. This is the federation half of recommendations.
//!
//! A [`CoVisitFact`] says "in my local sessions, catalog items A and B were engaged together `count`
//! times". The 10x over a centralized "people who watched X also watched Y" service is three structural
//! properties, none of which a central recommender has:
//!
//! - **Privacy-first.** The fact carries only two PUBLIC catalog ids and an integer count, never a user
//!   id, never a watch history, never who co-watched what. Collaborative filtering happens with nothing
//!   personal ever leaving the device.
//! - **No central server.** Facts merge as a CRDT ([`merge_covisit`]) so the co-occurrence map converges
//!   across peers in any gossip order.
//! - **Sybil-resistant, fail-closed.** A co-visit relationship is only allowed to move a recommendation
//!   when it is AUTHORITATIVE ([`authoritative_covisit_strength`]): own data, or a quorum of distinct
//!   trusted, non-greylisted signers, reusing the same gate as cache quorum. An untrusted or under-quorum
//!   pair contributes zero, so a lying peer can at worst waste nothing.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::hive_constants::{
    COVISIT_COUNT_CAP, COVISIT_PREFIX, MAX_CLOCK_SKEW_SECS, PUBLIC_TTL_CAP_SECS, QUORUM_N,
    REP_GREYLIST_THRESHOLD,
};
use crate::identity::{node_id_from_pubkey_b64, verify, NodeId, NodeIdentity};
use crate::trust::{TrustStore, TrustTier};
use crate::HiveError;

/// The canonical (unordered) pair key: `item_a <= item_b`, so `(X,Y)` and `(Y,X)` are one relationship.
pub type CoVisitKey = (String, String);

/// Per-pair, per-signer-node newest fact. Quorum counts DISTINCT signer nodes, so the map keeps one fact
/// per node per pair (unlike the cache map, which keeps a single newest claim).
pub type CoVisitMap = BTreeMap<CoVisitKey, BTreeMap<NodeId, CoVisitFact>>;

/// A signed item-item co-visit observation. Carries no user identity or history, only public ids + count.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CoVisitFact {
    pub version: u16,
    /// Lexicographically smaller item id of the pair.
    pub item_a: String,
    /// Lexicographically larger item id of the pair.
    pub item_b: String,
    /// Co-visit count, capped at [`COVISIT_COUNT_CAP`] so no single fact can dominate by magnitude.
    pub count: u32,
    pub verified_at: u64,
    pub ttl: u64,
    pub signer_pubkey: String,
    /// base64url of the detached signature over [`covisit_signing_bytes_for`].
    pub sig: String,
}

/// A catalog item id must be non-empty, free of `|` and control chars (it rides the `|`-delimited signing
/// string, so either would let two distinct facts collide on one signature), and length-capped.
fn validate_item_id(id: &str) -> Result<(), HiveError> {
    if id.is_empty() || id.chars().count() > 128 || id.chars().any(|c| c == '|' || c.is_control()) {
        Err(HiveError::MalformedItemId)
    } else {
        Ok(())
    }
}

/// Build the exact bytes a `CoVisitFact` signature covers:
///
/// ```text
/// b"vortx-covisit-v1\n" + item_a|item_b|count|verified_at|ttl|signer_pubkey
/// ```
///
/// Decimal integers, no padding. The pair MUST already be canonical (`item_a <= item_b`). This is the
/// cross-platform interop anchor: any client that builds these bytes the same way signs identically.
pub fn covisit_signing_bytes_for(
    item_a: &str,
    item_b: &str,
    count: u32,
    verified_at: u64,
    ttl: u64,
    signer_pubkey: &str,
) -> Vec<u8> {
    let canonical = format!("{item_a}|{item_b}|{count}|{verified_at}|{ttl}|{signer_pubkey}");
    let mut out = Vec::with_capacity(COVISIT_PREFIX.len() + canonical.len());
    out.extend_from_slice(COVISIT_PREFIX);
    out.extend_from_slice(canonical.as_bytes());
    out
}

impl CoVisitFact {
    /// Construct and sign a co-visit fact. Validates both ids, rejects a self-pair, canonicalizes the pair
    /// to `item_a <= item_b`, and caps the count. The signature covers the canonical bytes, not the JSON.
    pub fn create(
        identity: &NodeIdentity,
        item_x: &str,
        item_y: &str,
        count: u32,
        verified_at: u64,
        ttl: u64,
    ) -> Result<Self, HiveError> {
        validate_item_id(item_x)?;
        validate_item_id(item_y)?;
        if item_x == item_y {
            return Err(HiveError::MalformedItemId); // a co-visit needs two distinct items
        }
        let (item_a, item_b) = if item_x <= item_y {
            (item_x.to_string(), item_y.to_string())
        } else {
            (item_y.to_string(), item_x.to_string())
        };
        let count = count.min(COVISIT_COUNT_CAP);
        let signer_pubkey = identity.public_b64url();
        let bytes =
            covisit_signing_bytes_for(&item_a, &item_b, count, verified_at, ttl, &signer_pubkey);
        let sig = identity.sign(&bytes);
        Ok(Self {
            version: 1,
            item_a,
            item_b,
            count,
            verified_at,
            ttl,
            signer_pubkey,
            sig,
        })
    }

    /// The canonical bytes this fact's signature must cover.
    pub fn signing_bytes(&self) -> Vec<u8> {
        covisit_signing_bytes_for(
            &self.item_a,
            &self.item_b,
            self.count,
            self.verified_at,
            self.ttl,
            &self.signer_pubkey,
        )
    }

    /// Verify the fact's ed25519 signature against its own `signer_pubkey`.
    pub fn verify_signed(&self) -> Result<(), HiveError> {
        verify(&self.signer_pubkey, &self.signing_bytes(), &self.sig)
    }

    /// Whether this fact is past its effective expiry at `now`. The TTL is capped at
    /// [`PUBLIC_TTL_CAP_SECS`], so no signer can mint an immortal co-visit claim.
    pub fn is_expired(&self, now: u64) -> bool {
        let effective_ttl = self.ttl.min(PUBLIC_TTL_CAP_SECS);
        self.verified_at.saturating_add(effective_ttl) < now
    }

    /// The canonical pair key.
    pub fn pair(&self) -> CoVisitKey {
        (self.item_a.clone(), self.item_b.clone())
    }
}

/// Merge one incoming co-visit fact into the map (the state-based CRDT step). Returns `true` if it updated
/// the map. Drops (no state change) a fact that fails signature verification, is dated beyond the
/// clock-skew guard, or has already expired. Per `(pair, signer node)` it keeps the newest by the strict
/// total order `(verified_at, signer_pubkey, sig)`, so the merge is commutative, associative, and
/// idempotent and converges regardless of gossip order or duplicates.
pub fn merge_covisit(map: &mut CoVisitMap, incoming: CoVisitFact, now: u64) -> bool {
    if incoming.verify_signed().is_err() {
        return false;
    }
    if incoming.verified_at > now.saturating_add(MAX_CLOCK_SKEW_SECS) {
        return false;
    }
    if incoming.is_expired(now) {
        return false;
    }
    let node = match node_id_from_pubkey_b64(&incoming.signer_pubkey) {
        Ok(n) => n,
        Err(_) => return false,
    };
    let per_node = map.entry(incoming.pair()).or_default();
    match per_node.get(&node) {
        None => {
            per_node.insert(node, incoming);
            true
        }
        Some(cur) => {
            let wins = (
                incoming.verified_at,
                incoming.signer_pubkey.as_str(),
                incoming.sig.as_str(),
            ) > (cur.verified_at, cur.signer_pubkey.as_str(), cur.sig.as_str());
            if wins {
                per_node.insert(node, incoming);
                true
            } else {
                false
            }
        }
    }
}

/// All retained facts for one canonical pair (the input to [`authoritative_covisit_strength`]).
pub fn pair_facts<'a>(map: &'a CoVisitMap, item_x: &str, item_y: &str) -> Vec<&'a CoVisitFact> {
    let key = if item_x <= item_y {
        (item_x.to_string(), item_y.to_string())
    } else {
        (item_y.to_string(), item_x.to_string())
    };
    map.get(&key)
        .map(|per_node| per_node.values().collect())
        .unwrap_or_default()
}

/// The load-bearing invariant: the authoritative co-visit strength for one pair at `now`, trust-gated
/// exactly like cache quorum. Own data is authoritative (its own count). Otherwise at least [`QUORUM_N`]
/// DISTINCT trusted, non-greylisted, above-threshold signers must have fresh facts, and the strength is
/// the (saturating) sum of their counts. An untrusted or under-quorum pair returns `0`, so a co-visit
/// relationship can never move a recommendation without earning quorum. `facts` are assumed already
/// signature-verified (they come from the verified merge).
pub fn authoritative_covisit_strength(
    facts: &[CoVisitFact],
    trust: &TrustStore,
    now: u64,
) -> u32 {
    // Own observation is always authoritative.
    let own: Option<u32> = facts
        .iter()
        .filter(|f| {
            trust.tier(&f.signer_pubkey) == TrustTier::Own && !f.is_expired(now)
        })
        .map(|f| f.count)
        .max();
    if let Some(c) = own {
        return c;
    }
    // Quorum of distinct trusted, non-greylisted, above-threshold signers.
    let mut nodes: BTreeMap<NodeId, u32> = BTreeMap::new();
    for f in facts {
        if f.is_expired(now) {
            continue;
        }
        if trust.tier(&f.signer_pubkey) != TrustTier::Trusted {
            continue; // public signers are advisory, not quorum-eligible
        }
        if trust.greylisted(&f.signer_pubkey, now)
            || trust.rep_of(&f.signer_pubkey) < REP_GREYLIST_THRESHOLD
        {
            continue;
        }
        if let Ok(node) = node_id_from_pubkey_b64(&f.signer_pubkey) {
            // One fact per node already (post-merge); take the max if duplicated pre-merge.
            let e = nodes.entry(node).or_insert(0);
            *e = (*e).max(f.count);
        }
    }
    if nodes.len() < QUORUM_N {
        return 0;
    }
    nodes.values().fold(0u32, |acc, c| acc.saturating_add(*c))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id() -> NodeIdentity {
        NodeIdentity::generate().unwrap()
    }

    #[test]
    fn create_canonicalizes_pair_and_caps_count() {
        let n = id();
        let f = CoVisitFact::create(&n, "ttZZZ", "ttAAA", 99_999, 1000, 86_400).unwrap();
        assert_eq!(f.item_a, "ttAAA"); // canonical: smaller first
        assert_eq!(f.item_b, "ttZZZ");
        assert_eq!(f.count, COVISIT_COUNT_CAP); // capped
        assert!(f.verify_signed().is_ok());
    }

    #[test]
    fn self_pair_and_bad_ids_are_rejected() {
        let n = id();
        assert!(matches!(CoVisitFact::create(&n, "tt1", "tt1", 1, 0, 9), Err(HiveError::MalformedItemId)));
        assert!(matches!(CoVisitFact::create(&n, "a|b", "tt1", 1, 0, 9), Err(HiveError::MalformedItemId)));
        assert!(matches!(CoVisitFact::create(&n, "", "tt1", 1, 0, 9), Err(HiveError::MalformedItemId)));
    }

    #[test]
    fn own_fact_is_authoritative_without_quorum() {
        let me = id();
        let trust = TrustStore::new(me.public_b64url());
        let f = CoVisitFact::create(&me, "tt1", "tt2", 7, 1000, 86_400).unwrap();
        assert_eq!(authoritative_covisit_strength(&[f], &trust, 1000), 7);
    }

    #[test]
    fn under_quorum_public_signers_contribute_nothing() {
        let me = id();
        let trust = TrustStore::new(me.public_b64url());
        // Two random (public, untrusted) signers: not quorum-eligible at all.
        let a = id();
        let b = id();
        let fa = CoVisitFact::create(&a, "tt1", "tt2", 50, 1000, 86_400).unwrap();
        let fb = CoVisitFact::create(&b, "tt1", "tt2", 50, 1000, 86_400).unwrap();
        assert_eq!(authoritative_covisit_strength(&[fa, fb], &trust, 1000), 0);
    }

    #[test]
    fn quorum_of_trusted_signers_sums_counts() {
        let me = id();
        let mut trust = TrustStore::new(me.public_b64url());
        let signers: Vec<NodeIdentity> = (0..QUORUM_N).map(|_| id()).collect();
        let facts: Vec<CoVisitFact> = signers
            .iter()
            .map(|s| {
                trust.trust(s.public_b64url());
                CoVisitFact::create(s, "tt1", "tt2", 10, 1000, 86_400).unwrap()
            })
            .collect();
        assert_eq!(
            authoritative_covisit_strength(&facts, &trust, 1000),
            10 * QUORUM_N as u32
        );
    }

    #[test]
    fn merge_is_idempotent_and_keeps_newest_per_node() {
        let me = id();
        let mut map = CoVisitMap::new();
        let f1 = CoVisitFact::create(&me, "tt1", "tt2", 5, 1000, 86_400).unwrap();
        let f2 = CoVisitFact::create(&me, "tt1", "tt2", 9, 2000, 86_400).unwrap();
        assert!(merge_covisit(&mut map, f1.clone(), 3000));
        assert!(!merge_covisit(&mut map, f1.clone(), 3000)); // duplicate: no change
        assert!(merge_covisit(&mut map, f2, 3000)); // newer wins
        let facts = pair_facts(&map, "tt2", "tt1"); // order-independent lookup
        assert_eq!(facts.len(), 1);
        assert_eq!(facts[0].count, 9);
    }
}
