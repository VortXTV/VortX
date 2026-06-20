//! The asset resolve-order planner. Given the candidate sources for a `(MediaKey, AssetKind)`, decide the
//! order to try them: embedded in the container (instant), then a first-party provider (AniSkip /
//! SponsorBlock / chapter-db / addon sprite URL), then a trusted hive availability fact, then on-device
//! generation (the floor that never misses). A near-line-for-line port of the debrid `ResolvePlanner`:
//! same `dyn AssetView`, a `StaticAssetView` for tests/offline, a `VaultAssetView` gated by the hive
//! `TrustStore`, and a deterministic total order on `(rank, source_index)`.
//!
//! The load-bearing trust invariant, inherited from the debrid vault: a hive availability claim drives
//! what the player loads ONLY when an own/trusted (non-greylisted) signer made it and it has not expired.
//! A stranger's claim is advisory and produces no step.

use serde::{Deserialize, Serialize};
use vortx_hive::{TrustStore, TrustTier};

use crate::fact::{AssetKey, HiveAssetMap};
use crate::model::{AssetKind, MediaKey};

/// A candidate source for a playback asset.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "snake_case")]
pub enum AssetSource {
    /// Already present in the container/meta (ffprobe chapters, bingeGroup). Instant, zero cost.
    Embedded,
    /// A first-party provider returns the actual payload (AniSkip/SponsorBlock/chapter-db/sprite URL).
    Provider { provider: String },
    /// A hive `AssetFact` asserts a payload with this digest exists somewhere; gated by trust.
    Hive { digest: String },
    /// Generate locally (AVAssetImageGenerator / mpv chapters / server keyframe-gen). The floor.
    OnDevice,
}

/// Which tier a resolved step came from (mirrors the rank).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetTier {
    Embedded,
    Provider,
    Hive,
    OnDevice,
}

/// One step of the asset resolve plan. `rank` is the priority (0 = try first).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssetStep {
    pub source_index: usize,
    pub tier: AssetTier,
    pub rank: u8,
}

/// A read-only view of which assets the hive/cache can vouch for right now.
pub trait AssetView {
    /// Whether a trusted, fresh, available fact exists for this `(key, digest)` at `now` (unix seconds).
    fn available(&self, key: &AssetKey, digest: &str, now: u64) -> bool;
}

/// An in-memory view (offline planning / tests): explicit available `(key, digest)` pairs.
pub struct StaticAssetView {
    entries: Vec<(AssetKey, String)>,
}

impl StaticAssetView {
    pub fn new(entries: Vec<(AssetKey, String)>) -> Self {
        Self { entries }
    }
}

impl AssetView for StaticAssetView {
    fn available(&self, key: &AssetKey, digest: &str, _now: u64) -> bool {
        self.entries.iter().any(|(k, d)| k == key && d == digest)
    }
}

/// A view backed by the hive `AssetFact` vault, GATED by the trust store. A fact drives a hive step only
/// when it claims `available`, matches the requested key + digest, is not expired, AND is signed by an
/// own or trusted (allowlisted, non-greylisted) signer. A stranger's fact is advisory and never drives
/// playback, the same invariant `VaultCacheView` enforces for debrid links.
pub struct VaultAssetView<'a> {
    vault: &'a HiveAssetMap,
    trust: &'a TrustStore,
}

impl<'a> VaultAssetView<'a> {
    pub fn new(vault: &'a HiveAssetMap, trust: &'a TrustStore) -> Self {
        Self { vault, trust }
    }
}

impl AssetView for VaultAssetView<'_> {
    fn available(&self, key: &AssetKey, digest: &str, now: u64) -> bool {
        self.vault.values().any(|fact| {
            fact.available
                && &fact.key() == key
                && fact.digest == digest
                && !fact.is_expired(now)
                && matches!(
                    self.trust.tier(&fact.signer_pubkey),
                    TrustTier::Own | TrustTier::Trusted
                )
                && !self.trust.greylisted(&fact.signer_pubkey, now)
        })
    }
}

/// Plans the asset resolve order. Stateless: the ladder rank is fixed, only hive availability is dynamic.
pub struct AssetResolvePlanner;

impl AssetResolvePlanner {
    /// Build the ordered resolve plan for one asset kind. Ranks: 0 embedded, 1 provider, 2 hive (only when
    /// a trusted, fresh fact vouches for the digest), 3 on-device. A hive candidate whose fact is missing,
    /// untrusted, or expired is dropped (it never drives playback); on-device, when present, is the floor
    /// that always yields a step. The result is a deterministic total order on `(rank, source_index)`.
    pub fn plan(
        media_key: &MediaKey,
        kind: AssetKind,
        sources: &[AssetSource],
        view: &dyn AssetView,
        now: u64,
    ) -> Vec<AssetStep> {
        let key = AssetKey {
            media_id: media_key.meta_id.clone(),
            season: media_key.season.map(i64::from).unwrap_or(-1),
            episode: media_key.episode.map(i64::from).unwrap_or(-1),
            kind,
        };

        let mut steps: Vec<AssetStep> = sources
            .iter()
            .enumerate()
            .filter_map(|(i, source)| {
                let (tier, rank) = match source {
                    AssetSource::Embedded => (AssetTier::Embedded, 0u8),
                    AssetSource::Provider { .. } => (AssetTier::Provider, 1),
                    AssetSource::Hive { digest } => {
                        if view.available(&key, digest, now) {
                            (AssetTier::Hive, 2)
                        } else {
                            return None; // untrusted/expired/missing fact never drives playback
                        }
                    }
                    AssetSource::OnDevice => (AssetTier::OnDevice, 3),
                };
                Some(AssetStep {
                    source_index: i,
                    tier,
                    rank,
                })
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
    use crate::fact::{merge_asset_fact, AssetFact, HiveAssetMap};
    use vortx_hive::{NodeIdentity, TrustStore};

    fn movie() -> MediaKey {
        MediaKey::movie("tt1375666")
    }

    fn vault_fact(id: &NodeIdentity, digest: &str, verified_at: u64, ttl: u64) -> AssetFact {
        AssetFact::create(
            id,
            &movie(),
            AssetKind::Trickplay,
            true,
            digest,
            verified_at,
            ttl,
        )
        .unwrap()
    }

    #[test]
    fn embedded_then_provider_then_hive_then_ondevice_order() {
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&me, "sheet1", 1000, 100), 1000);
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultAssetView::new(&vault, &trust);

        // Deliberately scrambled input order; the plan must sort to the rank ladder.
        let sources = vec![
            AssetSource::OnDevice,
            AssetSource::Hive {
                digest: "sheet1".into(),
            },
            AssetSource::Provider {
                provider: "aniskip".into(),
            },
            AssetSource::Embedded,
        ];
        let plan = AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000);
        let tiers: Vec<AssetTier> = plan.iter().map(|s| s.tier).collect();
        assert_eq!(
            tiers,
            vec![
                AssetTier::Embedded,
                AssetTier::Provider,
                AssetTier::Hive,
                AssetTier::OnDevice
            ]
        );
    }

    #[test]
    fn ondevice_is_the_floor_when_all_miss() {
        // A stranger's hive claim is dropped; on-device is the only remaining step.
        let me = NodeIdentity::generate().unwrap();
        let stranger = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&stranger, "sheet1", 1000, 100), 1000);
        let trust = TrustStore::new(me.public_b64url()); // does not trust the stranger
        let view = VaultAssetView::new(&vault, &trust);

        let sources = vec![
            AssetSource::Hive {
                digest: "sheet1".into(),
            },
            AssetSource::OnDevice,
        ];
        let plan = AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].tier, AssetTier::OnDevice);
    }

    #[test]
    fn untrusted_signer_does_not_drive_asset() {
        // CRITICAL regression: a stranger's available fact must NOT produce a Hive step.
        let me = NodeIdentity::generate().unwrap();
        let stranger = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&stranger, "sheet1", 1000, 100), 1000);
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultAssetView::new(&vault, &trust);

        let sources = vec![AssetSource::Hive {
            digest: "sheet1".into(),
        }];
        let plan = AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000);
        assert!(plan.is_empty());
    }

    #[test]
    fn trusted_signer_drives_asset() {
        let me = NodeIdentity::generate().unwrap();
        let peer = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&peer, "sheet1", 1000, 100), 1000);
        let mut trust = TrustStore::new(me.public_b64url());
        trust.trust(peer.public_b64url());
        let view = VaultAssetView::new(&vault, &trust);

        let sources = vec![AssetSource::Hive {
            digest: "sheet1".into(),
        }];
        let plan = AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000);
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].tier, AssetTier::Hive);
    }

    #[test]
    fn expired_vault_asset_fact_is_ignored() {
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&me, "sheet1", 1000, 100), 1000);
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultAssetView::new(&vault, &trust);

        let sources = vec![AssetSource::Hive {
            digest: "sheet1".into(),
        }];
        // Fresh: drives a hive step.
        assert_eq!(
            AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000).len(),
            1
        );
        // After expiry: dropped.
        assert!(
            AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 5000)
                .is_empty()
        );
    }

    #[test]
    fn hive_digest_must_match_the_fact() {
        // A fact for a different sheet digest must not vouch for this candidate.
        let me = NodeIdentity::generate().unwrap();
        let mut vault = HiveAssetMap::new();
        merge_asset_fact(&mut vault, vault_fact(&me, "sheetA", 1000, 100), 1000);
        let trust = TrustStore::new(me.public_b64url());
        let view = VaultAssetView::new(&vault, &trust);

        let sources = vec![AssetSource::Hive {
            digest: "sheetB".into(),
        }];
        assert!(
            AssetResolvePlanner::plan(&movie(), AssetKind::Trickplay, &sources, &view, 1000)
                .is_empty()
        );
    }
}
