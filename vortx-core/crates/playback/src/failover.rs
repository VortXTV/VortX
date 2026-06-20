//! Runtime stream failover with federation-wide dead-link rot. When a stream fails mid-resolve or
//! mid-play, [`StreamFailover`] walks to the next-best candidate. The 10x over a local-only failover
//! (Syncler / AIOStreams): a PERMANENT failure ([`FailureSignal::ResolveError`]) mints a signed negative
//! [`vortx_hive::CacheFact`] (`cached: false`) so the dead link rots across the whole hive via the
//! existing LWW-CRDT, superseding any stale `cached: true`; a TRANSIENT failure
//! ([`FailureSignal::FirstByteTimeout`]) fails over locally but tells the federation nothing, so the
//! swarm only ever learns true facts. The walk is pure: it never returns a dead index twice and always
//! terminates.

use serde::{Deserialize, Serialize};
use vortx_hive::{CacheFact, DebridService, HiveError, NodeIdentity};

/// Why the current stream failed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureSignal {
    /// Permanent: a 404, a dead torrent, a debrid unrestrict failure. Worth rotting from the federation.
    ResolveError,
    /// Transient: a slow first byte (probably a network blip). Fail over but do not poison the hive.
    FirstByteTimeout,
}

/// A candidate stream in the ranked list. `infohash` + `service` are present for a debrid/torrent stream,
/// which is what makes a rot fact possible (a bare direct URL cannot be keyed into the cache federation).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamCandidate {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub infohash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub service: Option<DebridService>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
}

/// What to sign as a negative `CacheFact` to rot a permanently-dead link across the federation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RotFact {
    pub infohash: String,
    pub service: DebridService,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
}

/// The outcome of advancing past a failed candidate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailoverStep {
    /// Index of the next candidate to try, or `None` when the list is exhausted.
    pub next: Option<usize>,
    /// A negative fact to mint and gossip (only for a permanent failure of a debrid/torrent stream).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rot: Option<RotFact>,
}

/// A stateful failover walk over a ranked candidate list.
pub struct StreamFailover {
    candidates: Vec<StreamCandidate>,
    failed: Vec<bool>,
    current: Option<usize>,
}

impl StreamFailover {
    pub fn new(candidates: Vec<StreamCandidate>) -> Self {
        let current = if candidates.is_empty() { None } else { Some(0) };
        let failed = vec![false; candidates.len()];
        Self {
            candidates,
            failed,
            current,
        }
    }

    pub fn current(&self) -> Option<usize> {
        self.current
    }

    pub fn current_candidate(&self) -> Option<&StreamCandidate> {
        self.current.map(|i| &self.candidates[i])
    }

    pub fn is_exhausted(&self) -> bool {
        self.current.is_none()
    }

    /// Mark the current candidate failed, advance to the next un-failed candidate (best remaining in rank
    /// order), and return the step. A `ResolveError` on a debrid/torrent candidate yields a [`RotFact`].
    pub fn fail(&mut self, signal: FailureSignal) -> FailoverStep {
        let mut rot = None;
        if let Some(i) = self.current {
            self.failed[i] = true;
            if signal == FailureSignal::ResolveError {
                let c = &self.candidates[i];
                if let (Some(infohash), Some(service)) = (&c.infohash, c.service) {
                    rot = Some(RotFact {
                        infohash: infohash.clone(),
                        service,
                        file_idx: c.file_idx,
                    });
                }
            }
        }
        // Next-best remaining candidate in rank order.
        self.current = (0..self.candidates.len()).find(|&j| !self.failed[j]);
        FailoverStep {
            next: self.current,
            rot,
        }
    }
}

/// Mint the signed negative `CacheFact` (`cached: false`) that rots a dead link across the federation.
pub fn rot_cache_fact(
    identity: &NodeIdentity,
    rot: &RotFact,
    verified_at: u64,
    ttl: u64,
) -> Result<CacheFact, HiveError> {
    CacheFact::create(
        identity,
        &rot.infohash,
        rot.service,
        false, // not available: the link is dead
        rot.file_idx,
        None,
        None,
        verified_at,
        ttl,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

    fn debrid(id: &str) -> StreamCandidate {
        StreamCandidate {
            id: id.into(),
            infohash: Some(IH.into()),
            service: Some(DebridService::RealDebrid),
            file_idx: Some(0),
        }
    }

    fn direct(id: &str) -> StreamCandidate {
        StreamCandidate {
            id: id.into(),
            infohash: None,
            service: None,
            file_idx: None,
        }
    }

    #[test]
    fn advances_in_rank_order_and_terminates() {
        let mut f = StreamFailover::new(vec![direct("a"), direct("b"), direct("c")]);
        assert_eq!(f.current(), Some(0));
        assert_eq!(f.fail(FailureSignal::ResolveError).next, Some(1));
        assert_eq!(f.fail(FailureSignal::ResolveError).next, Some(2));
        assert_eq!(f.fail(FailureSignal::ResolveError).next, None);
        assert!(f.is_exhausted());
    }

    #[test]
    fn resolve_error_on_debrid_rots_the_link() {
        let mut f = StreamFailover::new(vec![debrid("a"), direct("b")]);
        let step = f.fail(FailureSignal::ResolveError);
        assert_eq!(step.next, Some(1));
        let rot = step.rot.expect("a permanent debrid failure must rot");
        assert_eq!(rot.infohash, IH);
        assert_eq!(rot.service, DebridService::RealDebrid);
    }

    #[test]
    fn transient_timeout_does_not_rot() {
        let mut f = StreamFailover::new(vec![debrid("a"), direct("b")]);
        let step = f.fail(FailureSignal::FirstByteTimeout);
        assert_eq!(step.next, Some(1));
        assert!(
            step.rot.is_none(),
            "a transient timeout must not poison the federation"
        );
    }

    #[test]
    fn direct_link_failure_has_no_rot_fact() {
        let mut f = StreamFailover::new(vec![direct("a"), direct("b")]);
        assert!(f.fail(FailureSignal::ResolveError).rot.is_none());
    }

    #[test]
    fn rot_fact_signs_a_negative_cachefact() {
        let id = NodeIdentity::generate().unwrap();
        let rot = RotFact {
            infohash: IH.into(),
            service: DebridService::RealDebrid,
            file_idx: Some(0),
        };
        let fact = rot_cache_fact(&id, &rot, 1000, 86_400).unwrap();
        assert!(!fact.cached);
        assert!(fact.verify_signed().is_ok());
    }
}
