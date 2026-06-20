//! End-to-end + property tests for per-profile ranking prefs threaded through the engine: prefs set once
//! via SetRankingPrefs are applied to every stream resolve that omits explicit prefs.

use proptest::prelude::*;
use serde_json::{json, Value};
use vortx_engine::{dispatch, init_runtime, resolve_json, Action, Engine, InMemoryEnv};
use vortx_ranking::{RankingPrefs, SourceClass};

fn env() -> InMemoryEnv {
    InMemoryEnv::new(1000)
}

const STREAMS: &str = r#"[{"name":"1080p BluRay REMUX"},{"name":"2160p WEBRip"}]"#;

fn top_raw_index(engine: &Engine, with_prefs: Option<&Value>) -> u64 {
    let mut req = json!({ "kind": "streams", "streams": serde_json::from_str::<Value>(STREAMS).unwrap() });
    if let Some(p) = with_prefs {
        req["prefs"] = p.clone();
    }
    let out = resolve_json(engine, &req.to_string());
    let parsed: Value = serde_json::from_str(&out).unwrap();
    parsed["ranked"][0]["raw_index"].as_u64().unwrap()
}

#[test]
fn stored_prefs_drive_resolution_when_request_omits_them() {
    let mut engine = init_runtime("owner", "Owner");
    // Fresh owner (default prefs): no source preference, so the 2160p stream wins on resolution.
    assert_eq!(top_raw_index(&engine, None), 1);

    // Set the owner's prefs to prefer remux; now a no-prefs resolve must float the remux (index 0).
    let prefs = RankingPrefs {
        source_type_order: vec![SourceClass::Remux],
        ..Default::default()
    };
    let r = dispatch(
        &mut engine,
        Action::SetRankingPrefs { id: "owner".into(), prefs },
        &env(),
    );
    assert!(r.ok);
    assert_eq!(top_raw_index(&engine, None), 0); // stored prefs applied
}

proptest! {
    /// The fallback is faithful: resolving with explicit prefs P is identical to setting P on the active
    /// profile and resolving with no prefs. The two ways to supply prefs cannot diverge.
    #[test]
    fn explicit_prefs_equal_stored_prefs(order in prop::collection::vec(0usize..3, 0..3)) {
        let classes = [SourceClass::Remux, SourceClass::BluRay, SourceClass::WebDl];
        // Dedup the generated order (a real source_type_order lists each class at most once).
        let mut seen = Vec::new();
        let source_type_order: Vec<SourceClass> = order
            .into_iter()
            .filter_map(|i| {
                let c = classes[i];
                if seen.contains(&i) { None } else { seen.push(i); Some(c) }
            })
            .collect();
        let prefs = RankingPrefs { source_type_order, ..Default::default() };
        let prefs_value = serde_json::to_value(&prefs).unwrap();

        let engine_explicit = init_runtime("owner", "Owner");
        let via_explicit = top_raw_index(&engine_explicit, Some(&prefs_value));

        let mut engine_stored = init_runtime("owner", "Owner");
        dispatch(&mut engine_stored, Action::SetRankingPrefs { id: "owner".into(), prefs }, &env());
        let via_stored = top_raw_index(&engine_stored, None);

        prop_assert_eq!(via_explicit, via_stored);
    }
}
