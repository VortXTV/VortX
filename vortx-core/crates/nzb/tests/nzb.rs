//! Cross-language conformance + property tests for the NZB engine.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_nzb::{health, parse_nzb, retrieval_order, NzbHealth};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    xml: String,
    health: NzbHealth,
    order: Vec<String>,
}

const SUITE: &str = include_str!("../conformance/nzb_vectors.json");

#[test]
fn nzb_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse nzb suite");
    for case in &suite.cases {
        let nzb = parse_nzb(&case.xml).unwrap_or_else(|e| panic!("{}: {e}", case.name));
        assert_eq!(health(&nzb), case.health, "health drifted for {}", case.name);
        let got: Vec<String> = retrieval_order(&nzb)
            .into_iter()
            .map(|s| s.message_id)
            .collect();
        assert_eq!(got, case.order, "retrieval order drifted for {}", case.name);
    }
}

proptest! {
    /// The parser is total: it never panics on any input (returns Ok or NzbError).
    #[test]
    fn parse_never_panics(s in ".{0,200}") {
        let _ = parse_nzb(&s);
    }

    /// The retrieval order partitions content before repair, and never loses or invents an article: the
    /// multiset of message ids equals every segment in the NZB.
    #[test]
    fn retrieval_is_content_first_and_lossless(
        files in prop::collection::vec(
            (any::<bool>(), prop::collection::vec((1u64..1000, 1u32..20, "[a-z]{1,4}"), 0..5)),
            0..5,
        ),
    ) {
        // Build a synthetic NZB document from the spec.
        let mut xml = String::from("<nzb>");
        let mut expected_ids: Vec<String> = Vec::new();
        for (i, (is_par2, segs)) in files.iter().enumerate() {
            let subject = if *is_par2 {
                format!("file{i}.vol00+1.par2 (1/{})", segs.len())
            } else {
                format!("file{i}.mkv (1/{})", segs.len())
            };
            xml.push_str(&format!("<file subject=\"{subject}\"><segments>"));
            for (j, (bytes, number, id)) in segs.iter().enumerate() {
                let mid = format!("{id}{i}_{j}");
                xml.push_str(&format!("<segment bytes=\"{bytes}\" number=\"{number}\">{mid}</segment>"));
                expected_ids.push(mid);
            }
            xml.push_str("</segments></file>");
        }
        xml.push_str("</nzb>");

        if let Ok(nzb) = parse_nzb(&xml) {
            let order = retrieval_order(&nzb);
            // Content (is_repair=false) all precede repair (is_repair=true).
            let first_repair = order.iter().position(|s| s.is_repair);
            if let Some(fr) = first_repair {
                prop_assert!(order[fr..].iter().all(|s| s.is_repair));
            }
            // Lossless: same multiset of message ids.
            let mut got: Vec<String> = order.into_iter().map(|s| s.message_id).collect();
            got.sort();
            expected_ids.sort();
            prop_assert_eq!(got, expected_ids);
        }
    }
}
