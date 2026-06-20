//! Cross-language conformance: a fixed sequence of JSON actions fed through `dispatch_json` must produce
//! exactly the pinned JSON results + events, on every platform bridge.

use serde::Deserialize;
use serde_json::Value;
use vortx_engine::{dispatch_json, get_state_json, init_runtime, DispatchResult, InMemoryEnv};
use vortx_state::{ProfileId, VortxStore};

#[derive(Deserialize)]
struct Suite {
    #[serde(rename = "ownerId")]
    owner_id: String,
    #[serde(rename = "ownerName")]
    owner_name: String,
    now: u64,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
struct Step {
    action: Value,
    expect: DispatchResult,
}

const SUITE: &str = include_str!("../conformance/dispatch_vectors.json");

#[test]
fn dispatch_sequence_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse dispatch suite");
    let mut engine = init_runtime(&suite.owner_id, &suite.owner_name);
    let env = InMemoryEnv::new(suite.now);

    for (i, step) in suite.steps.iter().enumerate() {
        let action_json = step.action.to_string();
        let result_json = dispatch_json(&mut engine, &action_json, &env);
        let got: DispatchResult =
            serde_json::from_str(&result_json).expect("dispatch returns valid JSON");
        assert_eq!(got, step.expect, "step {i} ({action_json}) diverged");
    }

    // After the sequence: we switched to kid (ghost failed), guest is tombstoned, owner untouched.
    let state: VortxStore = serde_json::from_str(&get_state_json(&engine)).unwrap();
    assert_eq!(state.active_profile_id, ProfileId::new("kid"));
    assert!(state.roster.get(&ProfileId::new("owner")).is_some());
    assert!(state.roster.get(&ProfileId::new("kid")).is_some());
    assert!(state.roster.get(&ProfileId::new("guest")).unwrap().deleted);
}
