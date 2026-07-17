//! Conformance + property tests for engine pagination.

use std::collections::HashSet;

use proptest::prelude::*;
use serde::Deserialize;
use vortx_source::{next_page, AddonPage, CatalogCursor};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    page1: Vec<AddonPage>,
    page2: Vec<AddonPage>,
    expect_page1: Vec<String>,
    expect_page2: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/pagination_vectors.json");

#[test]
fn pagination_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse pagination suite");
    for case in &suite.cases {
        let p1 = next_page(&CatalogCursor::default(), &case.page1);
        assert_eq!(p1.items, case.expect_page1, "{} page1", case.name);
        let p2 = next_page(&p1.cursor, &case.page2);
        assert_eq!(p2.items, case.expect_page2, "{} page2", case.name);
    }
}

fn addon_page() -> impl Strategy<Value = AddonPage> {
    ("[a-c]", prop::collection::vec("[x-z]", 0..4))
        .prop_map(|(addon_id, items)| AddonPage { addon_id, items })
}

fn round() -> impl Strategy<Value = Vec<AddonPage>> {
    prop::collection::vec(addon_page(), 0..4)
}

proptest! {
    #[test]
    fn no_item_appears_on_two_pages(rounds in prop::collection::vec(round(), 0..6)) {
        let mut cursor = CatalogCursor::default();
        let mut all: Vec<String> = Vec::new();
        for fetched in &rounds {
            let page = next_page(&cursor, fetched);
            all.extend(page.items.clone());
            cursor = page.cursor;
        }
        // Every emitted id across all pages is unique.
        let unique: HashSet<&String> = all.iter().collect();
        prop_assert_eq!(unique.len(), all.len());
    }

    #[test]
    fn skips_advance_monotonically(rounds in prop::collection::vec(round(), 0..6)) {
        let mut cursor = CatalogCursor::default();
        for fetched in &rounds {
            let before = cursor.skips.clone();
            let page = next_page(&cursor, fetched);
            for (addon, &skip) in &before {
                prop_assert!(page.cursor.skips.get(addon).copied().unwrap_or(0) >= skip);
            }
            cursor = page.cursor;
        }
    }

    #[test]
    fn next_page_is_deterministic(cursor_seed in round(), fetched in round()) {
        let cursor = next_page(&CatalogCursor::default(), &cursor_seed).cursor;
        prop_assert_eq!(next_page(&cursor, &fetched), next_page(&cursor, &fetched));
    }
}
