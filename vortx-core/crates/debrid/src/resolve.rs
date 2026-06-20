//! The resolve-order planner. Given the candidate sources for a title, decide the order to try them:
//! a direct URL first (instant, nothing to crash), then a debrid-cached magnet (instant via unrestrict),
//! then debrid-uncached (must download), then a raw torrent (P2P, needs the streaming server). The plan is
//! a deterministic total order, and cache status comes from a [`CacheView`] (the user's own store, or the
//! reused [`vortx_hive`] cross-node cache vault, where expired facts are ignored).

use serde::{Deserialize, Serialize};
use vortx_hive::{DebridService, HiveCacheMap, TrustStore, TrustTier};

/// A candidate playable source for a title.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResolveSource {
    /// An already-direct HTTP(S) URL.
    Direct { url: String },
    /// A torrent by infohash, optionally selecting a file.
    Magnet {
        infohash: String,
        #[serde(default, rename = "fileIdx", skip_serializing_if = "Option::is_none")]
        file_idx: Option<u32>,
    },
}

/// How a source will be resolved.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum ResolveMethod {
    /// Play the direct URL as-is.
    Direct,
    /// Resolve via a debrid service. `cached` true means instant.
    Debrid {
        service: DebridService,
        cached: bool,
    },
    /// Stream the torrent over P2P (needs the streaming server).
    Torrent,
}

/// One step of the resolve plan. `rank` is the priority (0 = try first).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResolveStep {
    pub source_index: usize,
    pub method: ResolveMethod,
    pub rank: u8,
}

/// A read-only view of which infohashes are cached on which of the user's services. `file_idx` selects a
/// file in a multi-file torrent (`None` = the whole torrent); a cache claim must match the SAME file.
pub trait CacheView {
    /// The user service this `(infohash, file_idx)` is cached on right now, if any (`now` = unix seconds).
    fn cached_service(
        &self,
        infohash: &str,
        file_idx: Option<u32>,
        now: u64,
    ) -> Option<DebridService>;
}

/// An in-memory cache view (offline planning / tests): explicit `(infohash, service)` cached pairs.
pub struct StaticCacheView {
    entries: Vec<(String, DebridService)>,
}

impl StaticCacheView {
    pub fn new(entries: Vec<(String, DebridService)>) -> Self {
        Self { entries }
    }
}

impl CacheView for StaticCacheView {
    // Matches by infohash only (this in-memory test/offline view does not track file granularity).
    fn cached_service(
        &self,
        infohash: &str,
        _file_idx: Option<u32>,
        _now: u64,
    ) -> Option<DebridService> {
        self.entries
            .iter()
            .find(|(hash, _)| hash == infohash)
            .map(|(_, service)| *service)
    }
}

/// A cache view backed by the reused hive CacheFact vault, scoped to the user's services and GATED by the
/// trust store. A fact only drives an instant-play (rank-1) decision when it claims `cached`, is not
/// expired, matches the requested `file_idx`, AND is signed by an OWN or TRUSTED (allowlisted, non-
/// greylisted) signer. Public / DMM-bulk facts are advisory only and never poison playback here, which is
/// the load-bearing "never play a cache claim without own-debrid or a trusted source" invariant.
///
/// Note: full >=3-signer quorum needs every fact per key, but the merged vault keeps only the latest per
/// key, so this conservatively requires a trusted (or own) signer. Quorum over a multi-fact accumulator is
/// a later phase; this is the correct minimal gate that restores the trust model on the playback path.
pub struct VaultCacheView<'a> {
    vault: &'a HiveCacheMap,
    services: &'a [DebridService],
    trust: &'a TrustStore,
}

impl<'a> VaultCacheView<'a> {
    pub fn new(
        vault: &'a HiveCacheMap,
        services: &'a [DebridService],
        trust: &'a TrustStore,
    ) -> Self {
        Self {
            vault,
            services,
            trust,
        }
    }
}

impl CacheView for VaultCacheView<'_> {
    fn cached_service(
        &self,
        infohash: &str,
        file_idx: Option<u32>,
        now: u64,
    ) -> Option<DebridService> {
        self.services.iter().copied().find(|service| {
            // The advisory bulk tier never drives instant-play.
            if *service == DebridService::DmmPublic {
                return false;
            }
            self.vault.values().any(|fact| {
                fact.cached
                    && fact.service == *service
                    && fact.infohash == infohash
                    && fact.file_idx == file_idx
                    && !fact.is_expired(now)
                    && matches!(
                        self.trust.tier(&fact.signer_pubkey),
                        TrustTier::Own | TrustTier::Trusted
                    )
                    && !self.trust.greylisted(&fact.signer_pubkey, now)
            })
        })
    }
}

/// Plans the resolve order for a profile's configured debrid services.
pub struct ResolvePlanner {
    /// The user's debrid services in preference order (the first is used for an uncached add).
    pub user_services: Vec<DebridService>,
}

impl ResolvePlanner {
    pub fn new(user_services: Vec<DebridService>) -> Self {
        Self { user_services }
    }

    /// Build the ordered resolve plan. Ranks: 0 direct, 1 debrid-cached, 2 debrid-uncached, 3 torrent.
    /// The result is a deterministic total order on `(rank, source_index)`.
    pub fn plan(
        &self,
        sources: &[ResolveSource],
        cache: &dyn CacheView,
        now: u64,
    ) -> Vec<ResolveStep> {
        let mut steps: Vec<ResolveStep> = sources
            .iter()
            .enumerate()
            .map(|(i, source)| {
                let (method, rank) = match source {
                    ResolveSource::Direct { .. } => (ResolveMethod::Direct, 0u8),
                    ResolveSource::Magnet { infohash, file_idx } => {
                        if let Some(service) = cache.cached_service(infohash, *file_idx, now) {
                            (
                                ResolveMethod::Debrid {
                                    service,
                                    cached: true,
                                },
                                1,
                            )
                        } else if let Some(service) = self.user_services.first().copied() {
                            (
                                ResolveMethod::Debrid {
                                    service,
                                    cached: false,
                                },
                                2,
                            )
                        } else {
                            (ResolveMethod::Torrent, 3)
                        }
                    }
                };
                ResolveStep {
                    source_index: i,
                    method,
                    rank,
                }
            })
            .collect();

        steps.sort_by(|a, b| {
            a.rank
                .cmp(&b.rank)
                .then(a.source_index.cmp(&b.source_index))
        });
        steps
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_hive::{merge_fact, CacheFact, NodeIdentity};

    const IH: &str = "aabbccddeeff00112233445566778899aabbccdd";

    #[test]
    fn direct_then_cached_debrid_then_torrent_then_uncached_order() {
        let planner = ResolvePlanner::new(vec![DebridService::RealDebrid]);
        let sources = vec![
            ResolveSource::Magnet {
                infohash: IH.into(),
                file_idx: None,
            }, // cached -> rank 1
            ResolveSource::Direct {
                url: "https://x/v.mkv".into(),
            }, // rank 0
        ];
        let cache = StaticCacheView::new(vec![(IH.to_string(), DebridService::RealDebrid)]);
        let plan = planner.plan(&sources, &cache, 0);
        assert_eq!(plan[0].method, ResolveMethod::Direct);
        assert_eq!(plan[0].source_index, 1);
        assert!(matches!(
            plan[1].method,
            ResolveMethod::Debrid { cached: true, .. }
        ));
    }

    #[test]
    fn cached_debrid_ranks_ahead_of_torrent() {
        let planner = ResolvePlanner::new(vec![]); // no user services -> uncached magnet becomes torrent
        let sources = vec![
            ResolveSource::Magnet {
                infohash: "ffff".into(),
                file_idx: None,
            }, // uncached, no svc -> torrent (3)
            ResolveSource::Magnet {
                infohash: IH.into(),
                file_idx: None,
            }, // cached -> 1
        ];
        let cache = StaticCacheView::new(vec![(IH.to_string(), DebridService::AllDebrid)]);
        let plan = planner.plan(&sources, &cache, 0);
        assert_eq!(plan[0].rank, 1);
        assert_eq!(plan[0].source_index, 1);
        assert_eq!(plan[1].method, ResolveMethod::Torrent);
    }

    #[test]
    fn no_user_service_uncached_magnet_is_torrent() {
        let planner = ResolvePlanner::new(vec![]);
        let sources = vec![ResolveSource::Magnet {
            infohash: "dead".into(),
            file_idx: None,
        }];
        let cache = StaticCacheView::new(vec![]);
        let plan = planner.plan(&sources, &cache, 0);
        assert_eq!(plan[0].method, ResolveMethod::Torrent);
    }

    #[test]
    fn uncached_with_user_service_is_debrid_uncached() {
        let planner = ResolvePlanner::new(vec![DebridService::TorBox]);
        let sources = vec![ResolveSource::Magnet {
            infohash: "dead".into(),
            file_idx: None,
        }];
        let cache = StaticCacheView::new(vec![]);
        let plan = planner.plan(&sources, &cache, 0);
        assert_eq!(
            plan[0].method,
            ResolveMethod::Debrid {
                service: DebridService::TorBox,
                cached: false
            }
        );
        assert_eq!(plan[0].rank, 2);
    }

    fn signed_fact(
        id: &NodeIdentity,
        service: DebridService,
        file_idx: Option<u32>,
        verified_at: u64,
        ttl: u64,
    ) -> CacheFact {
        CacheFact::create(
            id,
            IH,
            service,
            true,
            file_idx,
            None,
            None,
            verified_at,
            ttl,
        )
        .unwrap()
    }

    #[test]
    fn expired_vault_fact_is_ignored() {
        // An OWN fact merged while fresh, then queried after it expires, must NOT count as cached.
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveCacheMap::new();
        assert!(merge_fact(
            &mut vault,
            signed_fact(&me, DebridService::RealDebrid, None, 1000, 100),
            1000
        ));
        let services = [DebridService::RealDebrid];
        let trust = TrustStore::new(me.public_b64url()); // me = own tier
        let view = VaultCacheView::new(&vault, &services, &trust);

        assert_eq!(
            view.cached_service(IH, None, 1000),
            Some(DebridService::RealDebrid)
        ); // fresh
        assert_eq!(view.cached_service(IH, None, 5000), None); // expired
    }

    #[test]
    fn untrusted_signer_does_not_drive_playback() {
        // Regression (CRITICAL): a cached fact from a stranger (public tier) must NOT be actionable.
        let me = NodeIdentity::generate().unwrap();
        let stranger = NodeIdentity::generate().unwrap();
        let mut vault = HiveCacheMap::new();
        merge_fact(
            &mut vault,
            signed_fact(&stranger, DebridService::RealDebrid, None, 1000, 100),
            1000,
        );
        let services = [DebridService::RealDebrid];
        let trust = TrustStore::new(me.public_b64url()); // does not trust the stranger
        let view = VaultCacheView::new(&vault, &services, &trust);
        assert_eq!(view.cached_service(IH, None, 1000), None);
    }

    #[test]
    fn trusted_signer_drives_playback() {
        let me = NodeIdentity::generate().unwrap();
        let peer = NodeIdentity::generate().unwrap();
        let mut vault = HiveCacheMap::new();
        merge_fact(
            &mut vault,
            signed_fact(&peer, DebridService::AllDebrid, None, 1000, 100),
            1000,
        );
        let services = [DebridService::AllDebrid];
        let mut trust = TrustStore::new(me.public_b64url());
        trust.trust(peer.public_b64url()); // explicitly trusted
        let view = VaultCacheView::new(&vault, &services, &trust);
        assert_eq!(
            view.cached_service(IH, None, 1000),
            Some(DebridService::AllDebrid)
        );
    }

    #[test]
    fn file_idx_mismatch_is_not_cached() {
        // Regression (HIGH): a cached file-0 fact must not make file-1 report cached.
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveCacheMap::new();
        merge_fact(
            &mut vault,
            signed_fact(&me, DebridService::RealDebrid, Some(0), 1000, 100),
            1000,
        );
        let services = [DebridService::RealDebrid];
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultCacheView::new(&vault, &services, &trust);
        assert_eq!(
            view.cached_service(IH, Some(0), 1000),
            Some(DebridService::RealDebrid)
        );
        assert_eq!(view.cached_service(IH, Some(1), 1000), None);
    }

    #[test]
    fn dmm_public_service_never_drives_playback() {
        // The advisory bulk tier is never instant-play, even from an own/trusted signer.
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveCacheMap::new();
        merge_fact(
            &mut vault,
            signed_fact(&me, DebridService::DmmPublic, None, 1000, 100),
            1000,
        );
        let services = [DebridService::DmmPublic];
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultCacheView::new(&vault, &services, &trust);
        assert_eq!(view.cached_service(IH, None, 1000), None);
    }
}
