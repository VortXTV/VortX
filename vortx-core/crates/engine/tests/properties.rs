//! Property-based invariants for the dispatch core: totality (no panic on any input), determinism, and
//! the profile-action contract (switch succeeds iff the profile exists; add-then-switch always succeeds).

use proptest::prelude::*;
use vortx_engine::{dispatch, dispatch_json, init_runtime, Action, DispatchResult, InMemoryEnv};

fn env() -> InMemoryEnv {
    InMemoryEnv::new(1000)
}

proptest! {
    #[test]
    fn dispatch_json_never_panics_and_always_returns_a_result(raw in ".*") {
        // Arbitrary bytes in: a well-formed DispatchResult JSON out, never a panic.
        let mut engine = init_runtime("owner", "Owner");
        let out = dispatch_json(&mut engine, &raw, &env());
        let parsed: Result<DispatchResult, _> = serde_json::from_str(&out);
        prop_assert!(parsed.is_ok(), "dispatch_json must always emit a DispatchResult: {out}");
    }

    #[test]
    fn dispatch_is_deterministic(id in "[a-z]{1,8}", name in "[A-Za-z ]{1,12}") {
        // The same action on two identically-seeded engines yields the same result.
        let mut a = init_runtime("owner", "Owner");
        let mut b = init_runtime("owner", "Owner");
        let action = Action::AddProfile { id: id.clone(), name: name.clone() };
        prop_assert_eq!(dispatch(&mut a, action.clone(), &env()), dispatch(&mut b, action, &env()));
    }

    #[test]
    fn switch_succeeds_iff_profile_exists(id in "[a-z]{1,8}") {
        // A fresh engine has only "owner"; switching anywhere else is a clean failure.
        let mut engine = init_runtime("owner", "Owner");
        let r = dispatch(&mut engine, Action::SwitchProfile { id: id.clone() }, &env());
        prop_assert_eq!(r.ok, id == "owner");
    }

    #[test]
    fn add_then_switch_always_succeeds(id in "[a-z]{1,8}", name in "[A-Za-z ]{1,12}") {
        let mut engine = init_runtime("owner", "Owner");
        dispatch(&mut engine, Action::AddProfile { id: id.clone(), name }, &env());
        let r = dispatch(&mut engine, Action::SwitchProfile { id }, &env());
        prop_assert!(r.ok);
    }
}
