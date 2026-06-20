//! Frozen seek-to-tile math for trickplay scrubbing previews, plus the WebVTT `#xywh` cue form for
//! players we do not control. Pure integer arithmetic (no floats), so the crop rectangle for a given
//! seek is byte-identical on every platform. The mapping is pinned by conformance vectors.

use crate::model::TrickplaySprite;

/// Where a seek position lands inside the sprite grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TileLocation {
    /// Thumbnail index across all sheets (`seek_ms / interval_ms`).
    pub global_index: u64,
    /// Which sheet the thumbnail is on.
    pub sheet: u64,
    /// Index within that sheet.
    pub local_index: u64,
    pub row: u32,
    pub col: u32,
    /// Pixel crop of the thumbnail inside its sheet.
    pub crop_x: u32,
    pub crop_y: u32,
    pub crop_w: u32,
    pub crop_h: u32,
}

impl TrickplaySprite {
    /// Thumbnails per sheet (`cols * rows`), never zero (guards a malformed/deserialized sprite).
    pub fn tiles_per_sheet(&self) -> u64 {
        (self.cols.max(1) as u64) * (self.rows.max(1) as u64)
    }

    /// Map a playhead millisecond to the thumbnail crop that previews it. Integer-only; total (a zero
    /// `interval_ms`/`cols`/`rows` is clamped to 1 so this never divides by zero or panics).
    pub fn locate(&self, seek_ms: u64) -> TileLocation {
        let interval = self.interval_ms.max(1);
        let cols = self.cols.max(1) as u64;
        let per_sheet = self.tiles_per_sheet();

        let global_index = seek_ms / interval;
        let sheet = global_index / per_sheet;
        let local_index = global_index % per_sheet;
        let row = (local_index / cols) as u32;
        let col = (local_index % cols) as u32;

        TileLocation {
            global_index,
            sheet,
            local_index,
            row,
            col,
            crop_x: col * self.tile_w,
            crop_y: row * self.tile_h,
            crop_w: self.tile_w,
            crop_h: self.tile_h,
        }
    }

    /// The WebVTT spatial cue fragment for a located tile: `sprite-<sheet>.jpg#xywh=x,y,w,h`.
    pub fn webvtt_cue(&self, loc: &TileLocation) -> String {
        format!(
            "sprite-{}.jpg#xywh={},{},{},{}",
            loc.sheet, loc.crop_x, loc.crop_y, loc.crop_w, loc.crop_h
        )
    }
}

/// Parse a `sprite-<sheet>.jpg#xywh=x,y,w,h` WebVTT fragment back into `(sheet, x, y, w, h)`. The inverse
/// of [`TrickplaySprite::webvtt_cue`], so a cue round-trips.
pub fn parse_webvtt_cue(fragment: &str) -> Option<(u64, u32, u32, u32, u32)> {
    let (name, xywh) = fragment.split_once("#xywh=")?;
    let sheet: u64 = name
        .strip_prefix("sprite-")?
        .strip_suffix(".jpg")?
        .parse()
        .ok()?;
    let mut parts = xywh.split(',');
    let x = parts.next()?.parse().ok()?;
    let y = parts.next()?.parse().ok()?;
    let w = parts.next()?.parse().ok()?;
    let h = parts.next()?.parse().ok()?;
    if parts.next().is_some() {
        return None;
    }
    Some((sheet, x, y, w, h))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::AssetLocator;

    fn sheet_10x10() -> TrickplaySprite {
        TrickplaySprite {
            interval_ms: 5000,
            tile_w: 320,
            tile_h: 180,
            cols: 10,
            rows: 10,
            locator: AssetLocator::Digest { digest: "d".into() },
        }
    }

    #[test]
    fn seek_to_tile_math_is_frozen() {
        let loc = sheet_10x10().locate(37_000);
        assert_eq!(loc.global_index, 7);
        assert_eq!(loc.sheet, 0);
        assert_eq!(loc.row, 0);
        assert_eq!(loc.col, 7);
        assert_eq!(
            (loc.crop_x, loc.crop_y, loc.crop_w, loc.crop_h),
            (2240, 0, 320, 180)
        );
    }

    #[test]
    fn seek_crosses_sheet_boundary() {
        let loc = sheet_10x10().locate(520_000);
        assert_eq!(loc.global_index, 104);
        assert_eq!(loc.sheet, 1);
        assert_eq!(loc.local_index, 4);
        assert_eq!(loc.row, 0);
        assert_eq!(loc.col, 4);
    }

    #[test]
    fn webvtt_cue_xywh_roundtrips() {
        let sprite = sheet_10x10();
        let loc = sprite.locate(37_000);
        let cue = sprite.webvtt_cue(&loc);
        assert_eq!(cue, "sprite-0.jpg#xywh=2240,0,320,180");
        assert_eq!(parse_webvtt_cue(&cue), Some((0, 2240, 0, 320, 180)));
    }

    #[test]
    fn zero_interval_does_not_panic() {
        let mut s = sheet_10x10();
        s.interval_ms = 0;
        s.cols = 0;
        s.rows = 0;
        let loc = s.locate(123_456);
        assert_eq!(loc.row, 0);
        assert_eq!(loc.col, 0);
    }
}
