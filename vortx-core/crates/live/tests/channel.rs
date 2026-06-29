//! Cross-language conformance + property tests for canonical channel identity + dedup (LT3). The channel_id
//! grammar and the dedup merge are the cross-platform contract: the same provider playlists must collapse to
//! the same channels with the same ids on every device, so favorites/EPG/resume survive provider URL churn.

use std::collections::{BTreeMap, BTreeSet};

use proptest::prelude::*;
use serde::Deserialize;
use vortx_live::{build_channels, ChannelModel, M3uEntry, ProviderPlaylist};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    providers: Vec<ProviderPlaylist>,
    expect: Vec<ChannelModel>,
}

const SUITE: &str = include_str!("../conformance/channel_vectors.json");

#[test]
fn channels_match_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse channel suite");
    for c in &suite.cases {
        assert_eq!(
            build_channels(&c.providers),
            c.expect,
            "channel dedup drifted for {}",
            c.name
        );
    }
}

/// channel_id -> the set of feed URLs under it. This is the order-INDEPENDENT shape of the dedup: which feeds
/// belong to which identity, ignoring the (intentionally order-dependent) feed ranking.
fn id_to_urls(channels: &[ChannelModel]) -> BTreeMap<String, BTreeSet<String>> {
    channels
        .iter()
        .map(|c| {
            (
                c.channel_id.clone(),
                c.feeds.iter().map(|f| f.url.clone()).collect(),
            )
        })
        .collect()
}

fn feed(provider_idx: u8, channel_idx: u8, seq: usize) -> (u8, M3uEntry) {
    let e = M3uEntry {
        url: format!("http://{provider_idx}/{seq}"), // unique per feed
        duration_secs: -1,
        tvg_id: Some(format!("ch{channel_idx}")),
        display_name: format!("Chan {channel_idx}"),
        ..Default::default()
    };
    (provider_idx, e)
}

/// Group flat (provider_idx, entry) feeds into ProviderPlaylists for providers 0..3, preserving order.
fn playlists(feeds: &[(u8, M3uEntry)]) -> Vec<ProviderPlaylist> {
    (0u8..3)
        .map(|p| ProviderPlaylist {
            provider: p.to_string(),
            entries: feeds
                .iter()
                .filter(|(pi, _)| *pi == p)
                .map(|(_, e)| e.clone())
                .collect(),
        })
        .collect()
}

proptest! {
    // Union-find converges regardless of input order: the id -> feed-URLs grouping is identical whether the
    // providers and their entries are read forwards or backwards. (Feed RANK may differ by provider order;
    // the grouping must not.)
    #[test]
    fn dedup_is_order_independent(raw in prop::collection::vec((0u8..3, 0u8..5), 0..24)) {
        let feeds: Vec<(u8, M3uEntry)> = raw.iter().enumerate().map(|(seq, &(p, ch))| feed(p, ch, seq)).collect();

        let forward = build_channels(&playlists(&feeds));

        let mut rev = feeds.clone();
        rev.reverse();
        let mut rev_pls = playlists(&rev);
        rev_pls.reverse();
        let backward = build_channels(&rev_pls);

        prop_assert_eq!(id_to_urls(&forward), id_to_urls(&backward));
    }

    // Determinism + collision-freedom for distinct identities: N feeds across distinct logical channels
    // collapse to exactly the distinct-channel count, every channel_id is unique, and no feed is lost or
    // duplicated. Building twice yields byte-identical output.
    #[test]
    fn distinct_channels_get_distinct_ids_and_no_feed_is_lost(raw in prop::collection::vec((0u8..3, 0u8..5), 0..24)) {
        let feeds: Vec<(u8, M3uEntry)> = raw.iter().enumerate().map(|(seq, &(p, ch))| feed(p, ch, seq)).collect();
        let pls = playlists(&feeds);

        let out = build_channels(&pls);
        prop_assert_eq!(&out, &build_channels(&pls)); // deterministic

        let distinct_channels: BTreeSet<u8> = raw.iter().map(|&(_, ch)| ch).collect();
        prop_assert_eq!(out.len(), distinct_channels.len());

        let ids: BTreeSet<&str> = out.iter().map(|c| c.channel_id.as_str()).collect();
        prop_assert_eq!(ids.len(), out.len()); // all channel_ids unique

        let total_feeds: usize = out.iter().map(|c| c.feeds.len()).sum();
        prop_assert_eq!(total_feeds, feeds.len()); // every feed materialized exactly once
    }
}
