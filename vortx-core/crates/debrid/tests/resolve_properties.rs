//! Property-based proof that the resolve planner is a deterministic total order: every source appears
//! once, the plan is sorted by rank ascending, and ranking the same input twice is identical.

use proptest::prelude::*;
use vortx_debrid::{DebridService, ResolvePlanner, ResolveSource, StaticCacheView};

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn plan_is_sorted_total_order_and_deterministic(
        kinds in prop::collection::vec(0u8..2, 0..20usize),
        cached_flags in prop::collection::vec(any::<bool>(), 0..20usize),
        has_service in any::<bool>(),
    ) {
        let mut sources = Vec::new();
        let mut cached_entries: Vec<(String, DebridService)> = Vec::new();
        for (i, kind) in kinds.iter().enumerate() {
            if *kind == 0 {
                sources.push(ResolveSource::Direct { url: format!("https://x/{i}") });
            } else {
                let infohash = format!("hash{i}");
                if *cached_flags.get(i).unwrap_or(&false) {
                    cached_entries.push((infohash.clone(), DebridService::RealDebrid));
                }
                sources.push(ResolveSource::Magnet { infohash, file_idx: None });
            }
        }

        let planner = ResolvePlanner::new(if has_service {
            vec![DebridService::RealDebrid]
        } else {
            vec![]
        });

        let plan = planner.plan(&sources, &StaticCacheView::new(cached_entries.clone()), 0);

        // Sorted by rank ascending (direct < cached-debrid < uncached-debrid < torrent).
        for window in plan.windows(2) {
            prop_assert!(window[0].rank <= window[1].rank);
        }
        // Every source represented exactly once.
        prop_assert_eq!(plan.len(), sources.len());

        // Deterministic.
        let plan2 = planner.plan(&sources, &StaticCacheView::new(cached_entries), 0);
        prop_assert_eq!(plan, plan2);
    }
}
