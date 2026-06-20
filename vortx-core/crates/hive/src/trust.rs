//! Trust tiers and the actionability invariant.
//!
//! A cache claim is only allowed to drive playback ("actionable") when the node's OWN debrid confirms,
//! OR at least [`QUORUM_N`](crate::hive_constants::QUORUM_N) independent TRUSTED signers confirm. Public
//! (non-allowlisted) signers are advisory only until re-verified, and one node cannot manufacture quorum
//! (signers are deduped by node id, and a low-reputation signer contributes zero). This is what lets a
//! lying peer at worst waste one re-check, never poison playback.
//!
//! Facts passed to [`TrustStore::actionable_cached`] are assumed already signature-verified (they come
//! from the verified merge in `fact`); this evaluator decides authority, not authenticity.

use std::collections::{HashMap, HashSet};

use crate::fact::CacheFact;
use crate::hive_constants::{
    QUORUM_N, REP_ALPHA, REP_BETA, REP_DEFAULT, REP_GREYLIST_SECS, REP_GREYLIST_THRESHOLD,
};
use crate::identity::node_id_from_pubkey_b64;

/// Trust tiers, in descending authority.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TrustTier {
    /// Facts this node generated from its own debrid check. Always authoritative.
    Own,
    /// A signer in the local signed allowlist (a friend, your second node, the supernode).
    Trusted,
    /// Everyone else. Advisory / read-only until re-verified.
    Public,
}

#[derive(Debug, Clone, Copy)]
struct SignerRep {
    rep: f64,
    agree: u64,
    disagree: u64,
    greylisted_until: u64,
}

impl Default for SignerRep {
    fn default() -> Self {
        Self {
            rep: REP_DEFAULT,
            agree: 0,
            disagree: 0,
            greylisted_until: 0,
        }
    }
}

/// The node's view of who to trust: its own key, a trusted allowlist, and per-signer reputation.
pub struct TrustStore {
    self_pubkey: String,
    allowlist: HashSet<String>,
    rep: HashMap<String, SignerRep>,
}

impl TrustStore {
    /// A new store for a node whose own public key is `self_pubkey`.
    pub fn new(self_pubkey: impl Into<String>) -> Self {
        Self {
            self_pubkey: self_pubkey.into(),
            allowlist: HashSet::new(),
            rep: HashMap::new(),
        }
    }

    /// Add a signer's public key to the trusted allowlist.
    pub fn trust(&mut self, pubkey: impl Into<String>) {
        self.allowlist.insert(pubkey.into());
    }

    /// The trust tier of a signer.
    pub fn tier(&self, pubkey: &str) -> TrustTier {
        if pubkey == self.self_pubkey {
            TrustTier::Own
        } else if self.allowlist.contains(pubkey) {
            TrustTier::Trusted
        } else {
            TrustTier::Public
        }
    }

    /// A signer's current reputation (neutral default for an unseen signer).
    pub fn rep_of(&self, pubkey: &str) -> f64 {
        self.rep.get(pubkey).map(|r| r.rep).unwrap_or(REP_DEFAULT)
    }

    /// Whether a signer is currently greylisted (reputation collapsed) at `now`.
    pub fn greylisted(&self, pubkey: &str, now: u64) -> bool {
        self.rep
            .get(pubkey)
            .map(|r| r.greylisted_until > now)
            .unwrap_or(false)
    }

    /// Record that a signer's claim agreed with ground truth (own-debrid re-check). EWMA gain.
    pub fn record_agree(&mut self, pubkey: &str) {
        let entry = self.rep.entry(pubkey.to_string()).or_default();
        entry.rep += REP_ALPHA * (1.0 - entry.rep);
        entry.agree += 1;
    }

    /// Record that a signer's claim disagreed with ground truth. EWMA loss; greylist on collapse.
    pub fn record_disagree(&mut self, pubkey: &str, now: u64) {
        let entry = self.rep.entry(pubkey.to_string()).or_default();
        entry.rep -= REP_BETA * entry.rep;
        entry.disagree += 1;
        if entry.rep < REP_GREYLIST_THRESHOLD {
            entry.greylisted_until = now.saturating_add(REP_GREYLIST_SECS);
        }
    }

    /// The load-bearing invariant: is a positive cache claim for this key actionable (safe to drive the
    /// top pick) at `now`? True iff a fresh OWN fact says cached, OR at least [`QUORUM_N`] distinct
    /// trusted, non-greylisted, above-threshold signers have fresh `cached: true` facts. `facts` is the
    /// set of (already verified) facts seen for one cache key.
    pub fn actionable_cached(&self, facts: &[CacheFact], now: u64) -> bool {
        // Own debrid is always authoritative.
        if facts
            .iter()
            .any(|f| f.signer_pubkey == self.self_pubkey && f.cached && !f.is_expired(now))
        {
            return true;
        }
        // Quorum of distinct trusted signers.
        let mut nodes: HashSet<String> = HashSet::new();
        for f in facts {
            if !f.cached || f.is_expired(now) {
                continue;
            }
            if self.tier(&f.signer_pubkey) != TrustTier::Trusted {
                continue; // public signers are advisory, not quorum-eligible
            }
            if self.greylisted(&f.signer_pubkey, now)
                || self.rep_of(&f.signer_pubkey) < REP_GREYLIST_THRESHOLD
            {
                continue;
            }
            if let Ok(node_id) = node_id_from_pubkey_b64(&f.signer_pubkey) {
                nodes.insert(node_id);
            }
        }
        nodes.len() >= QUORUM_N
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fact::{CacheFact, DebridService};
    use crate::identity::NodeIdentity;

    const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

    fn signed(id: &NodeIdentity, cached: bool, verified_at: u64) -> CacheFact {
        CacheFact::create(
            id,
            IH,
            DebridService::RealDebrid,
            cached,
            Some(0),
            None,
            None,
            verified_at,
            86_400,
        )
        .unwrap()
    }

    #[test]
    fn three_distinct_trusted_signers_is_actionable() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let signers: Vec<NodeIdentity> =
            (0..3).map(|_| NodeIdentity::generate().unwrap()).collect();
        let mut facts = Vec::new();
        for s in &signers {
            store.trust(s.public_b64url());
            facts.push(signed(s, true, 1000));
        }
        assert!(store.actionable_cached(&facts, 2000));
    }

    #[test]
    fn two_trusted_signers_is_not_actionable() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let signers: Vec<NodeIdentity> =
            (0..2).map(|_| NodeIdentity::generate().unwrap()).collect();
        let mut facts = Vec::new();
        for s in &signers {
            store.trust(s.public_b64url());
            facts.push(signed(s, true, 1000));
        }
        assert!(!store.actionable_cached(&facts, 2000));
    }

    #[test]
    fn same_node_twice_does_not_make_quorum() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let a = NodeIdentity::generate().unwrap();
        let b = NodeIdentity::generate().unwrap();
        store.trust(a.public_b64url());
        store.trust(b.public_b64url());
        // A, A, B -> only 2 distinct nodes.
        let facts = vec![
            signed(&a, true, 1000),
            signed(&a, true, 1100),
            signed(&b, true, 1000),
        ];
        assert!(!store.actionable_cached(&facts, 2000));
    }

    #[test]
    fn self_fact_is_actionable_alone() {
        let me = NodeIdentity::generate().unwrap();
        let store = TrustStore::new(me.public_b64url());
        let facts = vec![signed(&me, true, 1000)];
        assert!(store.actionable_cached(&facts, 2000));
    }

    #[test]
    fn public_signers_do_not_count() {
        let me = NodeIdentity::generate().unwrap();
        let store = TrustStore::new(me.public_b64url()); // nobody trusted
        let signers: Vec<NodeIdentity> =
            (0..4).map(|_| NodeIdentity::generate().unwrap()).collect();
        let facts: Vec<CacheFact> = signers.iter().map(|s| signed(s, true, 1000)).collect();
        assert!(!store.actionable_cached(&facts, 2000));
    }

    #[test]
    fn low_rep_signer_excluded_from_quorum() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let signers: Vec<NodeIdentity> =
            (0..3).map(|_| NodeIdentity::generate().unwrap()).collect();
        for s in &signers {
            store.trust(s.public_b64url());
        }
        // Collapse the third signer's reputation below threshold.
        for _ in 0..3 {
            store.record_disagree(&signers[2].public_b64url(), 0);
        }
        let facts: Vec<CacheFact> = signers.iter().map(|s| signed(s, true, 1000)).collect();
        assert!(!store.actionable_cached(&facts, 2000)); // only 2 count
    }

    #[test]
    fn disagree_drops_rep_below_greylist() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let bad = NodeIdentity::generate().unwrap().public_b64url();
        for _ in 0..3 {
            store.record_disagree(&bad, 100);
        }
        assert!(store.rep_of(&bad) < REP_GREYLIST_THRESHOLD);
        assert!(store.greylisted(&bad, 200));
    }

    #[test]
    fn agree_raises_reputation() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let good = NodeIdentity::generate().unwrap().public_b64url();
        let before = store.rep_of(&good);
        store.record_agree(&good);
        assert!(store.rep_of(&good) > before);
    }

    #[test]
    fn expired_facts_do_not_count_toward_quorum() {
        let me = NodeIdentity::generate().unwrap();
        let mut store = TrustStore::new(me.public_b64url());
        let signers: Vec<NodeIdentity> =
            (0..3).map(|_| NodeIdentity::generate().unwrap()).collect();
        let mut facts = Vec::new();
        for s in &signers {
            store.trust(s.public_b64url());
            facts.push(signed(s, true, 1000)); // ttl 86400 -> dead at 87400
        }
        assert!(!store.actionable_cached(&facts, 200_000));
    }
}
