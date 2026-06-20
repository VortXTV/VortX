//! Property-based invariants for the playback-assets layer. The NEW BAR: the resolve plan is a
//! deterministic total order, the AssetFact CRDT converges regardless of merge order, and seek-to-tile is
//! always within the sprite grid.

use proptest::prelude::*;
use vortx_hive::NodeIdentity;
use vortx_playback::{
    merge_asset_fact, AssetFact, AssetKey, AssetKind, AssetLocator, AssetResolvePlanner,
    AssetSource, AssetView, HiveAssetMap, MediaKey, TrickplaySprite,
};

/// A view that vouches for everything: lets the planner keep every Hive candidate so the total-order
/// property can be checked on the full input (no drops).
struct AllAvailable;
impl AssetView for AllAvailable {
    fn available(&self, _key: &AssetKey, _digest: &str, _now: u64) -> bool {
        true
    }
}

fn any_source() -> impl Strategy<Value = AssetSource> {
    prop_oneof![
        Just(AssetSource::Embedded),
        Just(AssetSource::OnDevice),
        "[a-z]{1,6}".prop_map(|p| AssetSource::Provider { provider: p }),
        "[a-z0-9]{1,8}".prop_map(|d| AssetSource::Hive { digest: d }),
    ]
}

proptest! {
    #[test]
    fn planner_is_a_deterministic_total_order(sources in prop::collection::vec(any_source(), 0..24)) {
        let key = MediaKey::movie("tt1375666");
        let plan = AssetResolvePlanner::plan(&key, AssetKind::Trickplay, &sources, &AllAvailable, 0);

        // All-available view keeps every candidate.
        prop_assert_eq!(plan.len(), sources.len());

        // Sorted by (rank, source_index).
        for w in plan.windows(2) {
            prop_assert!((w[0].rank, w[0].source_index) <= (w[1].rank, w[1].source_index));
        }

        // The source indices are a permutation of 0..n.
        let mut idx: Vec<usize> = plan.iter().map(|s| s.source_index).collect();
        idx.sort_unstable();
        prop_assert_eq!(idx, (0..sources.len()).collect::<Vec<_>>());

        // Deterministic: same inputs -> identical plan.
        let again = AssetResolvePlanner::plan(&key, AssetKind::Trickplay, &sources, &AllAvailable, 0);
        prop_assert_eq!(plan, again);
    }

    #[test]
    fn asset_fact_merge_converges(ops in prop::collection::vec((0u64..12, any::<bool>()), 1..30)) {
        // One signer; facts vary by verified_at + availability. Merging in any order must converge to the
        // same map (commutative, associative, idempotent), because the state rule is a strict total order.
        let id = NodeIdentity::generate().unwrap();
        let key = MediaKey::movie("tt0111161");
        let now = 5000u64;
        let facts: Vec<AssetFact> = ops
            .iter()
            .map(|(dt, available)| {
                AssetFact::create(&id, &key, AssetKind::SkipMarkers, *available, "d", 1000 + dt, 86_400)
                    .unwrap()
            })
            .collect();

        let mut forward = HiveAssetMap::new();
        for f in facts.iter().cloned() {
            merge_asset_fact(&mut forward, f, now);
        }

        let mut backward = HiveAssetMap::new();
        for f in facts.iter().rev().cloned() {
            merge_asset_fact(&mut backward, f, now);
        }

        prop_assert_eq!(forward, backward);
    }

    #[test]
    fn seek_tile_is_never_out_of_grid(
        interval_ms in 1u64..60_000,
        cols in 1u32..20,
        rows in 1u32..20,
        nth in 0u64..5000,
    ) {
        let sprite = TrickplaySprite {
            interval_ms,
            tile_w: 320,
            tile_h: 180,
            cols,
            rows,
            locator: AssetLocator::Digest { digest: "d".into() },
        };
        // Any seek anywhere in the timeline lands in-grid.
        let seek_ms = nth.saturating_mul(interval_ms);
        let loc = sprite.locate(seek_ms);
        prop_assert!(loc.row < rows);
        prop_assert!(loc.col < cols);
    }
}
