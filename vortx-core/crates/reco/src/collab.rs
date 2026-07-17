//! The reco side of the collaborative-filtering plane: turn the hive's trust-gated co-visit map into a
//! per-candidate boost and re-rank the local [`crate::recommend`] output with it.
//!
//! The privacy / Sybil / federation properties live in the hive primitive ([`vortx_hive::CoVisitFact`]):
//! signed counts, CRDT merge, quorum authority. This module only CONSUMES the authoritative strength, so
//! the load-bearing invariant carries straight through: an untrusted or under-quorum co-visit pair yields
//! strength 0, contributes a 0 boost, and therefore cannot move a recommendation. The boost is purely
//! additive on top of the taste score, so with no authoritative co-visit data the ranking is unchanged.

use std::cmp::Ordering;

use vortx_hive::{authoritative_covisit_strength, pair_facts, CoVisitFact, CoVisitMap, TrustStore};

use crate::recommend::{Reason, Recommendation};

/// Saturating sum of per-seed authoritative strengths into one affinity. Pure and integer-deterministic,
/// so it is the cross-language conformance anchor for this layer.
pub fn affinity_from_strengths(strengths: &[u32]) -> u32 {
    strengths.iter().fold(0u32, |acc, s| acc.saturating_add(*s))
}

/// A read-only view over the federated co-visit map plus the node's trust store, evaluated at `now`.
pub struct CollabModel<'a> {
    pub map: &'a CoVisitMap,
    pub trust: &'a TrustStore,
    pub now: u64,
}

impl CollabModel<'_> {
    /// The authoritative collaborative affinity of `candidate` to a set of `seeds` (titles the profile has
    /// engaged with): the saturating sum, over each seed, of the quorum-gated co-visit strength of the
    /// (seed, candidate) pair. `0` when no seed pair is authoritative.
    pub fn affinity(&self, candidate: &str, seeds: &[String]) -> u32 {
        let strengths: Vec<u32> = seeds
            .iter()
            .map(|seed| {
                let facts: Vec<CoVisitFact> =
                    pair_facts(self.map, seed, candidate).into_iter().cloned().collect();
                authoritative_covisit_strength(&facts, self.trust, self.now)
            })
            .collect();
        affinity_from_strengths(&strengths)
    }
}

/// Tuning for the collaborative boost. `bonus = weight * affinity / (affinity + half)`: a bounded,
/// saturating curve so a huge affinity can never swamp the taste score, and `affinity = 0` gives `0`.
#[derive(Debug, Clone, Copy)]
pub struct CollabPrefs {
    /// Maximum bonus the collaborative signal can add to a recommendation score.
    pub weight: f32,
    /// Affinity at which the bonus reaches half its weight (the curve's knee).
    pub half: f32,
}

impl Default for CollabPrefs {
    fn default() -> Self {
        Self {
            weight: 0.5,
            half: 30.0,
        }
    }
}

/// The additive boost for a given affinity. `0` exactly when the affinity is `0`, so an under-quorum pair
/// (affinity 0) never changes a score.
pub fn collab_bonus(affinity: u32, prefs: &CollabPrefs) -> f32 {
    if affinity == 0 {
        return 0.0;
    }
    let a = affinity as f32;
    prefs.weight * (a / (a + prefs.half))
}

/// Re-rank `recs` with the collaborative boost: add each candidate's affinity-derived bonus to its score,
/// annotate boosted picks with a `co-watched` reason, and re-sort (score desc, then meta id for a stable
/// tie-break). With an empty / under-quorum map every bonus is 0, so the input order is preserved.
pub fn rerank_with_collab(
    mut recs: Vec<Recommendation>,
    seeds: &[String],
    model: &CollabModel,
    prefs: &CollabPrefs,
) -> Vec<Recommendation> {
    for r in &mut recs {
        let bonus = collab_bonus(model.affinity(&r.meta_id, seeds), prefs);
        if bonus > 0.0 {
            r.score += bonus;
            r.reasons.push(Reason::BecauseYouLike("co-watched".to_string()));
        }
    }
    recs.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.meta_id.cmp(&b.meta_id))
    });
    recs
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_hive::{merge_covisit, NodeIdentity};

    fn rec(id: &str, score: f32) -> Recommendation {
        Recommendation {
            meta_id: id.into(),
            score,
            reasons: vec![],
        }
    }

    #[test]
    fn affinity_saturates_and_sums() {
        assert_eq!(affinity_from_strengths(&[]), 0);
        assert_eq!(affinity_from_strengths(&[10, 0, 5]), 15);
        assert_eq!(affinity_from_strengths(&[u32::MAX, 10]), u32::MAX);
    }

    #[test]
    fn zero_affinity_leaves_order_unchanged() {
        let map = CoVisitMap::new();
        let me = NodeIdentity::generate().unwrap();
        let trust = TrustStore::new(me.public_b64url());
        let model = CollabModel { map: &map, trust: &trust, now: 1000 };
        let recs = vec![rec("a", 0.9), rec("b", 0.5)];
        let out = rerank_with_collab(recs.clone(), &["seed".into()], &model, &CollabPrefs::default());
        let ids: Vec<&str> = out.iter().map(|r| r.meta_id.as_str()).collect();
        assert_eq!(ids, vec!["a", "b"]); // unchanged; no boost added
        assert!(out.iter().all(|r| r.reasons.is_empty()));
    }

    #[test]
    fn quorum_backed_covisit_can_raise_a_candidate() {
        // 3 trusted signers attest that seed "s" co-visits candidate "b" strongly; "b" should overtake "a".
        let me = NodeIdentity::generate().unwrap();
        let mut trust = TrustStore::new(me.public_b64url());
        let mut map = CoVisitMap::new();
        for _ in 0..3 {
            let signer = NodeIdentity::generate().unwrap();
            trust.trust(signer.public_b64url());
            let f = CoVisitFact::create(&signer, "s", "b", 500, 1000, 21_600).unwrap();
            merge_covisit(&mut map, f, 1000);
        }
        let model = CollabModel { map: &map, trust: &trust, now: 1000 };
        let recs = vec![rec("a", 0.40), rec("b", 0.20)];
        let out = rerank_with_collab(recs, &["s".into()], &model, &CollabPrefs::default());
        assert_eq!(out[0].meta_id, "b"); // boosted past "a"
        assert!(out[0].reasons.iter().any(|r| matches!(r, Reason::BecauseYouLike(k) if k == "co-watched")));
    }
}
