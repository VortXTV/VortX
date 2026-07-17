//! Conformance + property tests for the AU1 audio metadata model. The critical invariant mirrors SH5: every
//! field is skip_serializing_if-default, so a plain AudioTrack serializes BYTE-IDENTICALLY to its minimal
//! {id,title} form and no existing wire vector regresses. The codec classification (snake_case + alias
//! tolerance + is_lossless) and the multi-disc order key are the cross-platform contracts.

use proptest::prelude::*;
use serde::Deserialize;
use serde_json::Value;
use vortx_protocol::{AudioCodec, AudioTrack};

#[derive(Deserialize)]
struct Suite {
    tracks: Vec<TrackCase>,
    codecs: Vec<CodecCase>,
    ordering: Vec<OrderingCase>,
}

#[derive(Deserialize)]
struct TrackCase {
    name: String,
    json: Value,
}

#[derive(Deserialize)]
struct CodecCase {
    wire: String,
    expect: String,
    lossless: bool,
}

#[derive(Deserialize)]
struct OrderingCase {
    name: String,
    tracks: Vec<AudioTrack>,
    expect_order: Vec<String>,
}

const SUITE: &str = include_str!("audio_vectors.json");

#[test]
fn audio_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse audio suite");

    // Each track json deserializes and re-serializes byte-identically (round-trip + minimal no-regression).
    for c in &suite.tracks {
        let track: AudioTrack = serde_json::from_value(c.json.clone()).expect("track parses");
        let back = serde_json::to_value(&track).unwrap();
        assert_eq!(back, c.json, "track serialization drifted for {}", c.name);
    }

    // from_wire maps to the expected codec, and is_lossless is correct.
    for c in &suite.codecs {
        let codec = AudioCodec::from_wire(&c.wire);
        assert_eq!(
            codec.wire(),
            c.expect,
            "codec from_wire drifted for {}",
            c.wire
        );
        assert_eq!(
            serde_json::to_value(codec).unwrap(),
            Value::String(c.expect.clone())
        );
        assert_eq!(
            codec.is_lossless(),
            c.lossless,
            "is_lossless drifted for {}",
            c.wire
        );
    }

    // Sorting by the order key produces the expected id sequence.
    for c in &suite.ordering {
        let mut tracks = c.tracks.clone();
        tracks.sort_by(|a, b| a.order_key().cmp(&b.order_key()));
        let ids: Vec<String> = tracks.iter().map(|t| t.id.clone()).collect();
        assert_eq!(ids, c.expect_order, "ordering drifted for {}", c.name);
    }
}

fn track(id: &str, disc: Option<u32>, trk: Option<u32>, title: &str) -> AudioTrack {
    AudioTrack {
        id: id.to_string(),
        title: title.to_string(),
        disc_no: disc,
        track_no: trk,
        ..Default::default()
    }
}

proptest! {
    // from_wire never panics on arbitrary input, and every canonical token round-trips through wire().
    #[test]
    fn codec_from_wire_is_total_and_round_trips(s in ".*") {
        let _ = AudioCodec::from_wire(&s); // no panic
        let canon = AudioCodec::from_wire(&s);
        prop_assert_eq!(AudioCodec::from_wire(canon.wire()), canon); // wire() token is a fixed point
        prop_assert_eq!(serde_json::to_value(canon).unwrap(), serde_json::Value::String(canon.wire().to_string()));
    }

    // The order key is a deterministic total order: sorting is idempotent and a permutation of the input
    // (no track dropped or duplicated), regardless of input order.
    #[test]
    fn order_key_is_a_deterministic_total_order(
        raw in prop::collection::vec(
            (prop::option::of(0u32..4), prop::option::of(0u32..30), 0u32..6),
            0..24,
        ),
    ) {
        let tracks: Vec<AudioTrack> = raw
            .iter()
            .enumerate()
            .map(|(i, &(disc, trk, t))| track(&format!("id{i}"), disc, trk, &format!("title{t}")))
            .collect();

        let mut sorted = tracks.clone();
        sorted.sort_by(|a, b| a.order_key().cmp(&b.order_key()));

        // Idempotent: sorting again changes nothing.
        let mut twice = sorted.clone();
        twice.sort_by(|a, b| a.order_key().cmp(&b.order_key()));
        prop_assert_eq!(
            twice.iter().map(|t| t.id.clone()).collect::<Vec<_>>(),
            sorted.iter().map(|t| t.id.clone()).collect::<Vec<_>>()
        );

        // Permutation: same multiset of ids before and after.
        let mut before: Vec<String> = tracks.iter().map(|t| t.id.clone()).collect();
        let mut after: Vec<String> = sorted.iter().map(|t| t.id.clone()).collect();
        before.sort();
        after.sort();
        prop_assert_eq!(before, after);

        // Sorted-ness: each adjacent pair is non-decreasing by the key.
        for w in sorted.windows(2) {
            prop_assert!(w[0].order_key() <= w[1].order_key());
        }
    }

    // A track carrying only id + title serializes to exactly those two keys (minimal no-regression).
    #[test]
    fn a_bare_track_serializes_to_two_keys(id in "[a-z0-9]{1,8}", title in "[A-Za-z ]{0,20}") {
        let t = AudioTrack { id: id.clone(), title: title.clone(), ..Default::default() };
        let v = serde_json::to_value(&t).unwrap();
        let obj = v.as_object().unwrap();
        prop_assert_eq!(obj.len(), 2);
        prop_assert_eq!(obj.get("id").unwrap(), &serde_json::Value::String(id));
        prop_assert_eq!(obj.get("title").unwrap(), &serde_json::Value::String(title));
    }
}
