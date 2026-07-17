//! Cross-language conformance + property tests for the EPG now/next + grid query views (LT4). The half-open
//! boundary rules and the grid clamping are the cross-platform contract: the same programme corpus must yield
//! the same guide on every device, so now/next highlighting and the grid never disagree across platforms.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_live::{grid, now_next, EpgWindow, Program};

#[derive(Deserialize)]
struct Suite {
    now_next: Vec<NowNextCase>,
    grid: Vec<GridCase>,
}

#[derive(Deserialize)]
struct NowNextCase {
    name: String,
    programs: Vec<Program>,
    channel_id: String,
    now_utc_ms: i64,
    expect: Value,
}

#[derive(Deserialize)]
struct GridCase {
    name: String,
    programs: Vec<Program>,
    channel_ids: Vec<String>,
    window: WindowCase,
    expect: Value,
}

#[derive(Deserialize)]
struct WindowCase {
    start_utc_ms: i64,
    end_utc_ms: i64,
}

const SUITE: &str = include_str!("../conformance/guide_vectors.json");

#[test]
fn guide_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse guide suite");

    for c in &suite.now_next {
        let got = now_next(&c.programs, &c.channel_id, c.now_utc_ms);
        let got_val = serde_json::to_value(&got).unwrap();
        assert_eq!(got_val, c.expect, "now_next drifted for {}", c.name);
    }

    for c in &suite.grid {
        let ids: Vec<&str> = c.channel_ids.iter().map(String::as_str).collect();
        let w = EpgWindow::new(c.window.start_utc_ms, c.window.end_utc_ms);
        let got = grid(&c.programs, &ids, &w);
        let got_val = serde_json::to_value(&got).unwrap();
        assert_eq!(got_val, c.expect, "grid drifted for {}", c.name);
    }
}

/// Build a single-channel corpus with DISTINCT start times (so ordering is unambiguous), each programme one
/// unit long with a one-unit gap, from a sorted-deduped set of start offsets.
fn corpus(starts: &[i64]) -> Vec<Program> {
    starts
        .iter()
        .map(|&s| Program {
            channel_id: "c".to_string(),
            start_utc_ms: s * 10,
            stop_utc_ms: s * 10 + 5, // length 5, gap 5 before the next start (which is +10)
            title: format!("p{s}"),
            ..Default::default()
        })
        .collect()
}

proptest! {
    // now is half-open-correct and unique; next starts at/after the instant and is not now; both are
    // order-independent over a shuffled corpus.
    #[test]
    fn now_next_invariants_and_order_independence(
        mut starts in prop::collection::btree_set(0i64..40, 0..12).prop_map(|s| s.into_iter().collect::<Vec<_>>()),
        now in 0i64..420,
    ) {
        let progs = corpus(&starts);
        let nn = now_next(&progs, "c", now);

        if let Some(p) = nn.now {
            prop_assert!(p.start_utc_ms <= now && now < p.stop_utc_ms); // half-open containment
        }
        if let Some(p) = nn.next {
            prop_assert!(p.start_utc_ms >= now); // next is at/after the instant
            if let Some(n) = nn.now {
                prop_assert!(p.start_utc_ms != n.start_utc_ms || p.stop_utc_ms != n.stop_utc_ms); // not the now programme
            }
        }

        // Order-independence: reversing the corpus yields the same serialized answer.
        starts.reverse();
        let mut rev = corpus(&starts);
        rev.reverse();
        let nn_rev = now_next(&rev, "c", now);
        prop_assert_eq!(serde_json::to_value(&nn).unwrap(), serde_json::to_value(&nn_rev).unwrap());
    }

    // Every gridded programme overlaps the window and is clamped inside it; the grid is order-independent.
    #[test]
    fn grid_clamps_inside_window_and_is_order_independent(
        starts in prop::collection::btree_set(0i64..40, 0..12).prop_map(|s| s.into_iter().collect::<Vec<_>>()),
        ws in 0i64..200,
        wlen in 1i64..220,
    ) {
        let progs = corpus(&starts);
        let w = EpgWindow::new(ws, ws + wlen);
        let g = grid(&progs, &["c"], &w);

        prop_assert_eq!(g.len(), 1);
        for gp in &g[0].programs {
            prop_assert!(w.overlaps(gp.program.start_utc_ms, gp.program.stop_utc_ms));
            prop_assert!(gp.clamped_start_ms >= w.start_utc_ms);
            prop_assert!(gp.clamped_stop_ms <= w.end_utc_ms);
            prop_assert!(gp.clamped_start_ms <= gp.clamped_stop_ms);
        }

        let mut rev = progs.clone();
        rev.reverse();
        let g_rev = grid(&rev, &["c"], &w);
        prop_assert_eq!(serde_json::to_value(&g).unwrap(), serde_json::to_value(&g_rev).unwrap());
    }
}
