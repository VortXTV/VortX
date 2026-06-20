//! Cross-language conformance: the seek-to-tile mapping must match the frozen vectors exactly. Pairs with
//! the frozen `asset_canonical_bytes_are_frozen` test in `src/fact.rs` (the AssetFact signing-byte anchor).

use serde::Deserialize;
use vortx_playback::{AssetLocator, TrickplaySprite};

#[derive(Deserialize)]
struct Suite {
    cases: Vec<Case>,
}

#[derive(Deserialize)]
struct Case {
    name: String,
    sprite: SpriteParams,
    seek_ms: u64,
    expect: Expect,
}

#[derive(Deserialize)]
struct SpriteParams {
    interval_ms: u64,
    tile_w: u32,
    tile_h: u32,
    cols: u32,
    rows: u32,
}

#[derive(Deserialize)]
struct Expect {
    global_index: u64,
    sheet: u64,
    local_index: u64,
    row: u32,
    col: u32,
    crop_x: u32,
    crop_y: u32,
    crop_w: u32,
    crop_h: u32,
}

const SUITE: &str = include_str!("../conformance/sprite_vectors.json");

#[test]
fn sprite_seek_to_tile_matches_conformance_vectors() {
    let suite: Suite = serde_json::from_str(SUITE).expect("parse sprite conformance suite");
    for c in &suite.cases {
        let sprite = TrickplaySprite {
            interval_ms: c.sprite.interval_ms,
            tile_w: c.sprite.tile_w,
            tile_h: c.sprite.tile_h,
            cols: c.sprite.cols,
            rows: c.sprite.rows,
            locator: AssetLocator::Digest { digest: "x".into() },
        };
        let loc = sprite.locate(c.seek_ms);
        assert_eq!(
            loc.global_index, c.expect.global_index,
            "global_index for {}",
            c.name
        );
        assert_eq!(loc.sheet, c.expect.sheet, "sheet for {}", c.name);
        assert_eq!(
            loc.local_index, c.expect.local_index,
            "local_index for {}",
            c.name
        );
        assert_eq!(loc.row, c.expect.row, "row for {}", c.name);
        assert_eq!(loc.col, c.expect.col, "col for {}", c.name);
        assert_eq!(
            (loc.crop_x, loc.crop_y, loc.crop_w, loc.crop_h),
            (
                c.expect.crop_x,
                c.expect.crop_y,
                c.expect.crop_w,
                c.expect.crop_h
            ),
            "crop for {}",
            c.name
        );
    }
}
