//! Cross-language conformance for the LT-CATCHUP URL template engine. The placeholder substitution and the
//! catchup-source / catchup-type resolution are the cross-platform contract: the same template + programme
//! window must render the same catchup URL on every device (a wrong substitution plays the wrong programme).

use serde::Deserialize;
use vortx_live::{catchup_url_for, render_catchup, CatchupCtx, M3uEntry};

#[derive(Deserialize)]
struct Suite {
    start_utc_ms: i64,
    stop_utc_ms: i64,
    now_ms: i64,
    render: Vec<RenderCase>,
    entry: Vec<EntryCase>,
}

#[derive(Deserialize)]
struct RenderCase {
    name: String,
    template: String,
    expect: String,
}

#[derive(Deserialize)]
struct EntryCase {
    name: String,
    attributes: Vec<(String, String)>,
    url: String,
    expect: Option<String>,
}

const SUITE: &str = include_str!("../conformance/catchup_vectors.json");

#[test]
fn catchup_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse catchup suite");
    let ctx = CatchupCtx::from_window(suite.start_utc_ms, suite.stop_utc_ms, suite.now_ms);

    for c in &suite.render {
        assert_eq!(
            render_catchup(&c.template, &ctx),
            c.expect,
            "render drifted for {}",
            c.name
        );
    }

    for c in &suite.entry {
        let entry = M3uEntry {
            url: c.url.clone(),
            duration_secs: -1,
            attributes: c.attributes.clone(),
            ..Default::default()
        };
        assert_eq!(
            catchup_url_for(&entry, suite.start_utc_ms, suite.stop_utc_ms, suite.now_ms),
            c.expect,
            "catchup_url_for drifted for {}",
            c.name
        );
    }
}
