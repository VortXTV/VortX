//! The ranker. Scores each stream by the locked weight contract and returns a deterministically ordered
//! best-first list, with `reasons` for explainability and DV/HDR/audio tags for the player router.
//!
//! Weight contract (the magnitudes encode the ordering, not the other way round):
//!   - JUNK sinks below every legit stream (`-100000`).
//!   - The user's source preference is the TOP key (`+100000` per preference rank), so a preferred source
//!     outranks a higher-resolution non-preferred one.
//!   - Resolution tier is the dominant ladder among same-preference streams (`15000` per step).
//!   - A debrid-cached stream gets a within-tier `+8000` bonus: it clears the within-tier spread but
//!     cannot jump the `15000` tier step.
//!   - Source class / HDR / audio are the within-tier spread; size is a small final tiebreaker.
//!
//! The score is FIXED-POINT, not floating: it is accumulated as an `i64` in milli-points (each human
//! weight above times `SCALE` = 1000) plus an integer size term computed by integer division. There is no
//! `f64` anywhere on the scoring path, so the score, and therefore the ordering, is byte-reproducible on
//! every platform (iOS, Android, a Cloudflare Worker) and can be pinned by cross-language conformance
//! vectors. The `reasons` strings keep the readable human magnitudes (e.g. `+100000`), not the scaled
//! values. The only `f64` left is the user-facing `max_filesize_gb` FILTER, which is a pref comparison,
//! not part of the deterministic score.

use serde::{Deserialize, Serialize};
use vortx_protocol::Stream;

use crate::parse::{parse, Audio, Hdr, ParsedData, Resolution, SourceClass};
use crate::prefs::RankingPrefs;

/// The resolution tier a ranked stream falls into.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tier {
    Uhd,
    Fhd,
    Hd,
    Sd,
    Unknown,
}

impl Tier {
    fn from_resolution(r: Resolution) -> Tier {
        match r {
            Resolution::P2160 => Tier::Uhd,
            Resolution::P1080 => Tier::Fhd,
            Resolution::P720 => Tier::Hd,
            Resolution::P480 => Tier::Sd,
            Resolution::Unknown => Tier::Unknown,
        }
    }
}

/// A ranked stream: its score, tier, the reasons that built the score, and the tags the player router
/// reads (so it never re-parses the label).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RankedStream {
    /// Index of this stream in the input slice.
    pub raw_index: usize,
    /// Fixed-point score in milli-points (human weight x 1000 + integer size term). Byte-reproducible.
    pub score: i64,
    pub tier: Tier,
    pub reasons: Vec<String>,
    pub is_dolby_vision: bool,
    pub is_hdr: bool,
    pub audio: Audio,
    pub parsed: ParsedData,
}

/// Milli-point scale: each human weight contributes `weight * SCALE` so the sub-point size tiebreaker
/// (0..12 points) survives as an integer (0..12000 milli) without any float.
const SCALE: i64 = 1_000;
/// Max size tiebreaker in milli-points (12 points).
const SIZE_MILLI_CAP: i64 = 12_000;
/// 1 GiB in bytes; the size term is `bytes * 150 / GIB` (= `gb * 0.15 * 1000`), clamped.
const GIB: i128 = 1_073_741_824;

const PREF_RANK_WEIGHT: i64 = 100_000;
const CACHED_BONUS: i64 = 8_000;
const JUNK_PENALTY: i64 = -100_000;

fn resolution_tier_score(r: Resolution) -> i64 {
    match r {
        Resolution::P2160 => 60_000,
        Resolution::P1080 => 45_000,
        Resolution::P720 => 30_000,
        Resolution::P480 => 15_000,
        Resolution::Unknown => 0,
    }
}

fn source_class_score(c: SourceClass) -> i64 {
    match c {
        SourceClass::Remux => 230,
        SourceClass::BluRay => 150,
        SourceClass::WebDl => 90,
        SourceClass::Web => 75,
        SourceClass::Hdtv => 40,
        SourceClass::Cam => 5,
        SourceClass::Unknown => 0,
    }
}

fn hdr_score(h: Hdr) -> i64 {
    match h {
        Hdr::DolbyVision => 120,
        Hdr::Hdr10Plus => 80,
        Hdr::Hdr10 => 60,
        Hdr::None => 0,
    }
}

fn audio_score(a: Audio) -> i64 {
    match a {
        Audio::Atmos => 90,
        Audio::TrueHd => 70,
        Audio::DtsHdMa => 60,
        Audio::DdPlus => 30,
        Audio::None => 0,
    }
}

/// The integer size tiebreaker in milli-points: `clamp(bytes * 150 / GiB, 0, 12000)`. A non-positive or
/// malformed `video_size` yields 0, so it can never sink a stream below the junk floor.
fn size_milli(bytes: i64) -> i64 {
    if bytes <= 0 {
        return 0;
    }
    ((bytes as i128 * 150) / GIB).min(SIZE_MILLI_CAP as i128) as i64
}

/// Raw `video_size` in bytes for the integer score term (distinct from `size_gb`, the f64 filter input).
fn size_bytes(s: &Stream) -> Option<i64> {
    s.behavior_hints.as_ref().and_then(|h| h.video_size)
}

fn label_of(s: &Stream) -> String {
    [
        s.name.as_deref(),
        s.title.as_deref(),
        s.description.as_deref(),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ")
}

fn size_gb(s: &Stream) -> Option<f64> {
    s.behavior_hints
        .as_ref()
        .and_then(|h| h.video_size)
        .map(|bytes| bytes as f64 / 1_073_741_824.0)
}

/// Rank `streams` for a profile. `cached[i]` marks stream `i` as debrid-cached (a missing entry is
/// treated as not cached). Returns the streams that pass the preference filters, ordered best-first by a
/// deterministic total order (score descending, then original index for stability).
pub fn rank(streams: &[Stream], prefs: &RankingPrefs, cached: &[bool]) -> Vec<RankedStream> {
    let mut out: Vec<RankedStream> = Vec::new();
    for (i, s) in streams.iter().enumerate() {
        let label = label_of(s);
        let lower = label.to_ascii_lowercase();

        if prefs
            .keyword_exclude
            .iter()
            .any(|k| lower.contains(&k.to_ascii_lowercase()))
        {
            continue;
        }
        if !prefs.keyword_include.is_empty()
            && !prefs
                .keyword_include
                .iter()
                .any(|k| lower.contains(&k.to_ascii_lowercase()))
        {
            continue;
        }

        let parsed = parse(&label);

        if let Some(maxr) = prefs.max_resolution {
            if parsed.resolution.rank() > maxr.rank() {
                continue;
            }
        }
        let gb = size_gb(s);
        if let (Some(max), Some(g)) = (prefs.max_filesize_gb, gb) {
            if g > max {
                continue;
            }
        }

        let mut reasons = Vec::new();
        let score = score_stream(
            &parsed,
            prefs,
            cached.get(i).copied().unwrap_or(false),
            size_bytes(s),
            &mut reasons,
        );
        out.push(RankedStream {
            raw_index: i,
            score,
            tier: Tier::from_resolution(parsed.resolution),
            reasons,
            is_dolby_vision: parsed.hdr == Hdr::DolbyVision,
            is_hdr: parsed.hdr != Hdr::None,
            audio: parsed.audio,
            parsed,
        });
    }

    // Pure integer order: score descending, then original index for a stable tiebreak.
    out.sort_by(|a, b| b.score.cmp(&a.score).then(a.raw_index.cmp(&b.raw_index)));
    out
}

fn score_stream(
    p: &ParsedData,
    prefs: &RankingPrefs,
    cached: bool,
    bytes: Option<i64>,
    reasons: &mut Vec<String>,
) -> i64 {
    // Accumulated in milli-points: each human weight is added as `weight * SCALE`, the size term is
    // already in milli. The reasons keep the readable human magnitudes.
    let mut s: i64 = 0;

    if p.junk {
        s += JUNK_PENALTY * SCALE;
        reasons.push("junk/fake (-100000)".to_string());
    }

    if !prefs.source_type_order.is_empty() {
        if let Some(idx) = prefs
            .source_type_order
            .iter()
            .position(|c| *c == p.source_class)
        {
            let pref_rank = (prefs.source_type_order.len() - idx) as i64;
            let bonus = pref_rank * PREF_RANK_WEIGHT;
            s += bonus * SCALE;
            reasons.push(format!("preferred source {:?} (+{bonus})", p.source_class));
        }
    }

    let tier = resolution_tier_score(p.resolution);
    s += tier * SCALE;
    reasons.push(format!("{:?} (+{tier})", p.resolution));

    if cached && prefs.cached_first {
        s += CACHED_BONUS * SCALE;
        reasons.push("cached (+8000)".to_string());
    }

    let sc = source_class_score(p.source_class);
    if sc != 0 {
        s += sc * SCALE;
        reasons.push(format!("{:?} (+{sc})", p.source_class));
    }
    let h = hdr_score(p.hdr);
    if h != 0 {
        s += h * SCALE;
        reasons.push(format!("{:?} (+{h})", p.hdr));
    }
    let a = audio_score(p.audio);
    if a != 0 {
        s += a * SCALE;
        reasons.push(format!("{:?} (+{a})", p.audio));
    }
    if p.repack {
        s += 5 * SCALE;
        reasons.push("repack (+5)".to_string());
    }
    if let Some(b) = bytes {
        // A small NON-NEGATIVE integer tiebreaker. A malformed negative video_size (i64) yields 0, so it
        // can never drive the score below the junk floor or let an add-on self-suppress its own streams.
        s += size_milli(b);
    }

    s
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream(label: &str) -> Stream {
        Stream {
            name: Some(label.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn user_preferred_source_outranks_higher_res_nonpreferred() {
        let prefs = RankingPrefs {
            source_type_order: vec![SourceClass::Remux],
            ..Default::default()
        };
        let streams = [stream("1080p BluRay REMUX"), stream("2160p WEBRip")];
        let ranked = rank(&streams, &prefs, &[false, false]);
        assert_eq!(ranked[0].raw_index, 0); // the remux, despite lower resolution
        assert!(ranked[0].score > ranked[1].score);
    }

    #[test]
    fn cached_1080p_beats_uncached_1080p_but_not_4k() {
        let prefs = RankingPrefs::default();
        let streams = [
            stream("1080p WEB-DL"), // cached
            stream("1080p WEB-DL"), // uncached
            stream("2160p WEB-DL"), // uncached
        ];
        let ranked = rank(&streams, &prefs, &[true, false, false]);
        assert_eq!(ranked[0].raw_index, 2); // 4k wins the tier step
        assert_eq!(ranked[1].raw_index, 0); // cached 1080p
        assert_eq!(ranked[2].raw_index, 1); // uncached 1080p
    }

    #[test]
    fn keyword_exclude_removes_a_stream() {
        let prefs = RankingPrefs {
            keyword_exclude: vec!["cam".to_string()],
            ..Default::default()
        };
        let streams = [stream("1080p WEB-DL"), stream("1080p HDCAM")];
        let ranked = rank(&streams, &prefs, &[false, false]);
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].raw_index, 0);
    }

    #[test]
    fn junk_sinks_below_legit() {
        let prefs = RankingPrefs::default();
        let streams = [stream("2160p FAKE upscale"), stream("480p WEB-DL")];
        let ranked = rank(&streams, &prefs, &[false, false]);
        assert_eq!(ranked[0].raw_index, 1); // the legit 480p beats the fake 4k
    }

    #[test]
    fn max_resolution_filter_drops_above_ceiling() {
        let prefs = RankingPrefs {
            max_resolution: Some(Resolution::P720),
            ..Default::default()
        };
        let streams = [stream("2160p WEB-DL"), stream("720p WEB-DL")];
        let ranked = rank(&streams, &prefs, &[false, false]);
        assert_eq!(ranked.len(), 1);
        assert_eq!(ranked[0].parsed.resolution, Resolution::P720);
    }

    #[test]
    fn ranked_stream_carries_player_tags_and_reasons() {
        let prefs = RankingPrefs::default();
        let streams = [stream("2160p BluRay REMUX Dolby Vision Atmos")];
        let ranked = rank(&streams, &prefs, &[true]);
        assert!(ranked[0].is_dolby_vision);
        assert!(ranked[0].is_hdr);
        assert_eq!(ranked[0].audio, Audio::Atmos);
        assert!(ranked[0].reasons.iter().any(|r| r.contains("cached")));
    }

    #[test]
    fn ranking_is_deterministic() {
        let prefs = RankingPrefs::default();
        let streams = [
            stream("1080p WEB-DL"),
            stream("2160p BluRay REMUX"),
            stream("720p HDTV"),
        ];
        let a = rank(&streams, &prefs, &[false, false, false]);
        let b = rank(&streams, &prefs, &[false, false, false]);
        assert_eq!(a, b);
    }

    #[test]
    fn negative_video_size_is_clamped_not_a_self_suppress() {
        // Regression: a malformed negative video_size must not sink a legit stream below the junk floor.
        use vortx_protocol::StreamBehaviorHints;
        let prefs = RankingPrefs::default();
        let mut legit = stream("1080p WEB-DL");
        legit.behavior_hints = Some(StreamBehaviorHints {
            video_size: Some(i64::MIN),
            ..Default::default()
        });
        let junk = stream("2160p FAKE upscale");
        let ranked = rank(&[legit, junk], &prefs, &[false, false]);
        assert_eq!(ranked[0].raw_index, 0); // legit still beats junk
        assert!(ranked[0].score > 0);
    }
}
