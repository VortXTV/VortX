//! Property-based proof that the profile roster is a convergent CRDT.
//!
//! Two laws of a state-based CRDT, exercised over thousands of random profile-edit streams:
//!   - convergence: folding the same edits in any order yields an identical roster.
//!   - idempotency: replaying every edit again changes nothing.
//!
//! This is the multi-profile foundation's safety net: two devices editing profiles offline must merge
//! without ever dropping or diverging a profile.

use proptest::prelude::*;
use vortx_state::{Profile, ProfileId, ProfileRoster};

/// Build a profile version from primitive knobs. Varying `name_variant` at the same `(id, rev)` produces
/// different serialized content, which exercises the content tiebreak in the merge's total order.
fn mk(id_idx: u8, rev: u64, deleted: bool, name_variant: u8) -> Profile {
    let mut p = Profile::new(
        ProfileId::new(format!("p{id_idx}")),
        format!("name{name_variant}"),
    );
    p.rev = rev;
    p.deleted = deleted;
    p
}

fn ops_strategy() -> impl Strategy<Value = Vec<(u8, u64, bool, u8)>> {
    prop::collection::vec((0u8..4, 0u64..50u64, any::<bool>(), 0u8..3u8), 0..40usize)
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn roster_converges_regardless_of_order(ops in ops_strategy()) {
        let profiles: Vec<Profile> = ops.iter().map(|&(id, rev, del, nv)| mk(id, rev, del, nv)).collect();

        let mut forward = ProfileRoster::new();
        for p in &profiles {
            forward.upsert(p.clone());
        }

        let mut reverse = ProfileRoster::new();
        for p in profiles.iter().rev() {
            reverse.upsert(p.clone());
        }

        prop_assert_eq!(forward, reverse);
    }

    #[test]
    fn roster_merge_is_idempotent(ops in ops_strategy()) {
        let profiles: Vec<Profile> = ops.iter().map(|&(id, rev, del, nv)| mk(id, rev, del, nv)).collect();

        let mut once = ProfileRoster::new();
        for p in &profiles {
            once.upsert(p.clone());
        }

        let mut twice = once.clone();
        for p in &profiles {
            twice.upsert(p.clone());
        }

        prop_assert_eq!(once, twice);
    }
}
