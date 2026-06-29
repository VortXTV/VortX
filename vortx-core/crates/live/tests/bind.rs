//! Conformance + property tests for LT-BIND (EPG channel binding). The fallback chain (tvg-id -> normalized
//! name -> none) and the never-mis-bind guarantee are the cross-platform contract: the same channels + EPG
//! must reconcile to the same programme keys on every device.

use proptest::prelude::*;
use serde::Deserialize;
use vortx_live::{bind_epg, epg_channel_id_for, ChannelModel, EpgChannel};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    channel: ChannelModel,
    epg_channels: Vec<EpgChannel>,
    expect: Option<String>,
}

const SUITE: &str = include_str!("../conformance/bind_vectors.json");

#[test]
fn bind_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse bind suite");
    for c in &suite.cases {
        assert_eq!(
            epg_channel_id_for(&c.channel, &c.epg_channels),
            c.expect,
            "binding drifted for {}",
            c.name
        );
    }
}

fn channel(channel_id: &str, display_name: &str) -> ChannelModel {
    ChannelModel {
        channel_id: channel_id.to_string(),
        display_name: display_name.to_string(),
        ..Default::default()
    }
}

fn epg(id: &str, name: &str) -> EpgChannel {
    EpgChannel {
        id: id.to_string(),
        display_names: vec![name.to_string()],
        icon: None,
    }
}

proptest! {
    // Binding is deterministic and order-independent: shuffling the EPG list yields the same result.
    #[test]
    fn binding_is_order_independent(
        tvg in "[a-z][a-z0-9.]{0,6}",
        ids in prop::collection::vec("[a-zA-Z][a-zA-Z0-9.]{0,6}", 0..6),
    ) {
        let ch = channel(&format!("t:{tvg}"), "Some Channel");
        let epgs: Vec<EpgChannel> = ids.iter().map(|id| epg(id, "Some Channel")).collect();
        let forward = epg_channel_id_for(&ch, &epgs);
        let mut rev = epgs.clone();
        rev.reverse();
        prop_assert_eq!(&forward, &epg_channel_id_for(&ch, &rev));
        // Determinism on the same input.
        prop_assert_eq!(&forward, &epg_channel_id_for(&ch, &epgs));
    }

    // A tvg-id channel whose tvg matches an EPG id (case-insensitively) always binds to a real EPG id, and
    // that id is one of the inputs (never invented).
    #[test]
    fn a_matching_tvg_always_binds_to_an_input_id(
        tvg in "[a-z][a-z0-9.]{0,6}",
    ) {
        let ch = channel(&format!("t:{tvg}"), "Zzz No Name Match");
        // Put an EPG entry with the same tvg in upper case among distractors with non-matching names.
        let mut epgs = vec![epg("zzz.distractor.1", "Other A"), epg(&tvg.to_uppercase(), "Other B")];
        epgs.push(epg("zzz.distractor.2", "Other C"));
        let bound = epg_channel_id_for(&ch, &epgs).expect("tvg must bind");
        prop_assert!(epgs.iter().any(|e| e.id == bound)); // returned id is a real input id
        prop_assert_eq!(bound.to_ascii_lowercase(), tvg); // and it is the tvg match
    }

    // bind_epg never panics on arbitrary channel ids / names and only maps channels that resolve.
    #[test]
    fn bind_epg_is_panic_free_and_only_maps_matches(
        chans in prop::collection::vec(("t:[a-z.]{1,6}", "[A-Za-z ]{0,10}"), 0..6),
        epg_ids in prop::collection::vec("[a-z.]{1,6}", 0..6),
    ) {
        let channels: Vec<ChannelModel> = chans.iter().map(|(id, name)| channel(id, name)).collect();
        let epgs: Vec<EpgChannel> = epg_ids.iter().map(|id| epg(id, "X")).collect();
        let map = bind_epg(&channels, &epgs);
        // Every mapped value is a real EPG id, and every key is a real channel id.
        for (k, v) in &map {
            prop_assert!(channels.iter().any(|c| &c.channel_id == k));
            prop_assert!(epgs.iter().any(|e| &e.id == v));
        }
    }
}
