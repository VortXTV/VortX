//! Conformance + property tests for meta-addressed progress / Continue Watching (engine-owned CW rules).

use std::collections::BTreeMap;

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_engine::{dispatch, dispatch_json, init_runtime, Action, Engine, InMemoryEnv};
use vortx_state::{CW_CAP, FINISHED_PERMILLE};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    actions: Vec<Value>,
    expect_cw: Vec<String>,
    expect_watched: BTreeMap<String, Vec<String>>,
    expect_resume_keys: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/progress_vectors.json");

/// The active profile's library, read back out of the full state snapshot.
fn active_library(engine: &Engine) -> Value {
    let state: Value = serde_json::from_str(&vortx_engine::get_state_json(engine)).unwrap();
    let active = state["activeProfileId"].as_str().unwrap().to_string();
    state["libraries"][active].clone()
}

#[test]
fn progress_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse progress suite");
    let env = InMemoryEnv::new(1000);
    for case in &suite.cases {
        let mut engine = init_runtime("owner", "Owner");
        for (i, action) in case.actions.iter().enumerate() {
            // A fresh env per step would share `now`; bump it so newest-first ordering is well defined.
            let env_i = InMemoryEnv::new(1000 + i as u64);
            let _ = dispatch_json(&mut engine, &action.to_string(), &env_i);
        }
        let _ = &env;
        let lib = active_library(&engine);

        let cw: Vec<String> = lib["continueWatching"].as_array().unwrap().iter().map(|c| c["id"].as_str().unwrap().to_string()).collect();
        assert_eq!(cw, case.expect_cw, "CW drifted for {}", case.name);

        let mut watched: BTreeMap<String, Vec<String>> = BTreeMap::new();
        if let Some(w) = lib["watched"].as_object() {
            for (k, v) in w {
                watched.insert(k.clone(), v["videoIds"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect());
            }
        }
        assert_eq!(watched, case.expect_watched, "watched drifted for {}", case.name);

        let mut resume_keys: Vec<String> = lib["resume"].as_object().map(|r| r.keys().cloned().collect()).unwrap_or_default();
        resume_keys.sort();
        let mut want = case.expect_resume_keys.clone();
        want.sort();
        assert_eq!(resume_keys, want, "resume keys drifted for {}", case.name);
    }
}

proptest! {
    /// Over any sequence of progress reports, Continue Watching obeys the engine's rules: never longer than
    /// CW_CAP, no duplicate ids, and every CW item is still in progress (below the finished threshold).
    #[test]
    fn cw_invariants_hold(
        reports in prop::collection::vec((0usize..8, 0u64..600, 1u64..601), 0..60),
    ) {
        let mut engine = init_runtime("owner", "Owner");
        for (i, (id, pos, dur)) in reports.iter().enumerate() {
            let pos_ms = pos * 1000;
            let dur_ms = dur * 1000;
            dispatch(
                &mut engine,
                Action::ReportProgress {
                    meta_id: format!("m{id}"),
                    video_id: None,
                    name: "M".into(),
                    position_ms: pos_ms.min(dur_ms),
                    duration_ms: dur_ms,
                    content_kind: None,
                },
                &InMemoryEnv::new(1000 + i as u64),
            );
        }
        let lib = active_library(&engine);
        let cw = lib["continueWatching"].as_array().unwrap();

        prop_assert!(cw.len() <= CW_CAP);
        let mut seen = std::collections::HashSet::new();
        for item in cw {
            let id = item["id"].as_str().unwrap();
            prop_assert!(seen.insert(id.to_string()), "duplicate {id} in CW");
            let progress = item["progress"].as_u64().unwrap() as u32;
            prop_assert!(progress < FINISHED_PERMILLE, "finished item still in CW");
        }
    }
}
