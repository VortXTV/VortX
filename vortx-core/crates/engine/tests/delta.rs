//! Conformance + property tests for the delta-state persistence API: the host persists only the changed
//! records (O(changed)), not the whole store (O(total)). The properties pin the dirty-tracking invariant.

use std::collections::BTreeSet;

use proptest::prelude::*;
use serde_json::Value;
use vortx_engine::{dispatch, get_state_delta_json, init_runtime, Action, InMemoryEnv};

fn env() -> InMemoryEnv {
    InMemoryEnv::new(1000)
}

#[test]
fn delta_wire_shape_is_empty_then_changed_then_empty() {
    let mut e = init_runtime("owner", "Owner");
    // A fresh runtime has no pending changes -> an empty object (every field skip-serialized).
    assert_eq!(get_state_delta_json(&mut e), "{}");

    dispatch(&mut e, Action::AddProfile { id: "kid".into(), name: "Kid".into() }, &env());
    let d: Value = serde_json::from_str(&get_state_delta_json(&mut e)).unwrap();
    // Only the changed profile is present; no activeProfileId (it did not move), no libraries.
    let ids: Vec<&str> = d["profiles"].as_array().unwrap().iter().map(|p| p["id"].as_str().unwrap()).collect();
    assert_eq!(ids, vec!["kid"]);
    assert!(d.get("activeProfileId").is_none());
    assert!(d.get("libraries").is_none());

    // Taking again clears: empty object.
    assert_eq!(get_state_delta_json(&mut e), "{}");
}

proptest! {
    /// Over any dispatch sequence, the delta contains ONLY profiles we actually mutated, and a second
    /// take is always empty (dirty was cleared). This is the O(changed)-not-O(total) guarantee.
    #[test]
    fn delta_contains_only_mutated_profiles_and_clears(
        ops in prop::collection::vec((0u8..3, 0usize..4), 0..20),
    ) {
        let mut e = init_runtime("owner", "Owner");
        // Pre-create the id space so set_parental/switch have targets.
        for i in 0..4 {
            dispatch(&mut e, Action::AddProfile { id: format!("p{i}"), name: "P".into() }, &env());
        }
        let _ = get_state_delta_json(&mut e); // clear the setup churn

        let mut mutated: BTreeSet<String> = BTreeSet::new();
        for (op, i) in &ops {
            let id = format!("p{i}");
            match op {
                0 => {
                    dispatch(&mut e, Action::SetParental { id: id.clone(), kids: true, maturity_ceiling: None }, &env());
                    mutated.insert(id);
                }
                1 => {
                    dispatch(&mut e, Action::SetRankingPrefs { id: id.clone(), prefs: Default::default() }, &env());
                    mutated.insert(id);
                }
                _ => {
                    // Switch changes the active id + its library bucket, not a profile record.
                    dispatch(&mut e, Action::SwitchProfile { id }, &env());
                }
            }
        }

        let delta: Value = serde_json::from_str(&get_state_delta_json(&mut e)).unwrap();
        if let Some(profiles) = delta.get("profiles").and_then(|p| p.as_array()) {
            for p in profiles {
                let id = p["id"].as_str().unwrap().to_string();
                prop_assert!(mutated.contains(&id), "delta carried an unmutated profile {id}");
            }
        }
        // A second take is always empty (dirty cleared).
        prop_assert_eq!(get_state_delta_json(&mut e), "{}");
    }
}
