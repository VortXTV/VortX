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
    pub score: f64,
    pub tier: Tier,
    pub reasons: Vec<String>,
    pub is_dolby_vision: bool,
    pub is_hdr: bool,
    pub audio: Audio,
    pub parsed: ParsedData,
}

const PREF_RANK_WEIGHT: f64 = 100_000.0;
const CACHED_BONUS: f64 = 8_000.0;
const JUNK_PENALTY: f64 = -100_000.0;

fn resolution_tier_score(r: Resolution) -> f64 {
    match r {
        Resolution::P2160 => 60_000.0,
        Resolution::P1080 => 45_000.0,
        Resolution::P720 => 30_000.0,
        Resolution::P480 => 15_000.0,
        Resolution::Unknown => 0.0,
    }
}

fn source_class_score(c: SourceClass) -> f64 {
    match c {
        SourceClass::Remux => 230.0,
        SourceClass::BluRay => 150.0,
        SourceClass::WebDl => 90.0,
        SourceClass::Web => 75.0,
        SourceClass::Hdtv => 40.0,
        SourceClass::Cam => 5.0,
        SourceClass::Unknown => 0.0,
    }
}

fn hdr_score(h: Hdr) -> f64 {
    match h {
        Hdr::DolbyVision => 120.0,
        Hdr::Hdr10Plus => 80.0,
        Hdr::Hdr10 => 60.0,
        Hdr::None => 0.0,
    }
}

fn audio_score(a: Audio) -> f64 {
    match a {
        Audio::Atmos => 90.0,
        Audio::TrueHd => 70.0,
        Audio::DtsHdMa => 60.0,
        Audio::DdPlus => 30.0,
        Audio::None => 0.0,
    }
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
            gb,
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

    out.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.raw_index.cmp(&b.raw_index))
    });
    out
}

fn score_stream(
    p: &ParsedData,
    prefs: &RankingPrefs,
    cached: bool,
    gb: Option<f64>,
    reasons: &mut Vec<String>,
) -> f64 {
    let mut s = 0.0;

    if p.junk {
        s += JUNK_PENALTY;
        reasons.push("junk/fake (-100000)".to_string());
    }

    if !prefs.source_type_order.is_empty() {
        if let Some(idx) = prefs
            .source_type_order
            .iter()
            .position(|c| *c == p.source_class)
        {
            let pref_rank = (prefs.source_type_order.len() - idx) as f64;
            let bonus = pref_rank * PREF_RANK_WEIGHT;
            s += bonus;
            reasons.push(format!("preferred source {:?} (+{bonus})", p.source_class));
        }
    }

    let tier = resolution_tier_score(p.resolution);
    s += tier;
    reasons.push(format!("{:?} (+{tier})", p.resolution));

    if cached && prefs.cached_first {
        s += CACHED_BONUS;
        reasons.push("cached (+8000)".to_string());
    }

    let sc = source_class_score(p.source_class);
    if sc != 0.0 {
        s += sc;
        reasons.push(format!("{:?} (+{sc})", p.source_class));
    }
    let h = hdr_score(p.hdr);
    if h != 0.0 {
        s += h;
        reasons.push(format!("{:?} (+{h})", p.hdr));
    }
    let a = audio_score(p.audio);
    if a != 0.0 {
        s += a;
        reasons.push(format!("{:?} (+{a})", p.audio));
    }
    if p.repack {
        s += 5.0;
        reasons.push("repack (+5)".to_string());
    }
    if let Some(g) = gb {
        s += (g * 0.15).min(12.0);
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
}
