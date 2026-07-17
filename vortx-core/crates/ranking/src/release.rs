//! Full release-name parsing (PTT / RTN grade). [`parse_release`] is the foundational primitive the rest
//! of the engine assumes: cross-source dedup, the anti-fraud filter, season-pack mapping, and the UI all
//! read a structured [`ReleaseMeta`] rather than re-scanning raw strings. It REUSES the ranking
//! [`crate::parse::parse`] for the quality tokens (resolution / source / HDR / audio / codec / season /
//! episode) so there is one tokenizer and one source of truth, and adds the orthogonal fields a raw
//! release name carries: a clean title, the year, the release group, the edition, languages, and the
//! proper/repack split. Pure string to struct: no IO, no clock, deterministic, never panics.

use serde::{Deserialize, Serialize};

use crate::parse::{parse, Audio, Hdr, Resolution, SourceClass};

/// Everything structured that can be lifted from a raw release name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReleaseMeta {
    /// The title with quality/episode/year markers stripped (`The Movie`).
    #[serde(default)]
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u16>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    pub resolution: Resolution,
    pub source_class: SourceClass,
    pub hdr: Hdr,
    pub audio: Audio,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub channels: Option<String>,
    /// `Extended` / `Directors Cut` / `Remastered` / `IMAX` / ...
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edition: Option<String>,
    /// The release group (the token after the final `-`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    /// Language codes/markers found (`multi`, `dual`, `en`, `fr`, ...).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub languages: Vec<String>,
    #[serde(default)]
    pub proper: bool,
    #[serde(default)]
    pub repack: bool,
}

/// Parse a raw release name into structured metadata.
pub fn parse_release(name: &str) -> ReleaseMeta {
    let lower = name.to_ascii_lowercase();
    let quality = parse(name); // reuse the one tokenizer for the quality fields

    ReleaseMeta {
        title: extract_title(name),
        year: extract_year(name),
        season: quality.season,
        episode: quality.episode,
        resolution: quality.resolution,
        source_class: quality.source_class,
        hdr: quality.hdr,
        audio: quality.audio,
        codec: quality.codec,
        channels: quality.channels,
        edition: extract_edition(&lower),
        group: extract_group(name),
        languages: extract_languages(name),
        proper: lower.contains("proper"),
        repack: lower.contains("repack"),
    }
}

/// Split a name into tokens on the usual release-name separators.
fn split_tokens(s: &str) -> Vec<&str> {
    s.split(['.', ' ', '_', '(', ')', '[', ']', '-'])
        .filter(|t| !t.is_empty())
        .collect()
}

/// A 4-digit token in a plausible release-year range.
fn token_year(tok: &str) -> Option<u16> {
    if tok.len() == 4 && tok.bytes().all(|b| b.is_ascii_digit()) {
        tok.parse::<u16>()
            .ok()
            .filter(|y| (1900..=2099).contains(y))
    } else {
        None
    }
}

fn extract_year(name: &str) -> Option<u16> {
    split_tokens(name).into_iter().find_map(token_year)
}

/// Whether a (lowercased) token marks the end of the title (a year, resolution, season/episode, or a
/// source token).
fn is_marker(tok: &str) -> bool {
    if token_year(tok).is_some() {
        return true;
    }
    if tok.contains("2160") || tok.contains("1080") || tok.contains("720") || tok.contains("480") {
        return true;
    }
    if tok == "4k" || tok == "uhd" {
        return true;
    }
    // sNN / sNNeNN season-episode token.
    if tok.starts_with('s') && tok[1..].chars().next().is_some_and(|c| c.is_ascii_digit()) {
        return true;
    }
    matches!(
        tok,
        "bluray"
            | "web"
            | "webrip"
            | "webdl"
            | "hdtv"
            | "remux"
            | "bdrip"
            | "brrip"
            | "hdcam"
            | "cam"
            | "dvdrip"
            | "dvd"
            | "proper"
            | "repack"
    )
}

fn extract_title(name: &str) -> String {
    let toks = split_tokens(name);
    let end = toks
        .iter()
        .position(|t| is_marker(&t.to_ascii_lowercase()))
        .unwrap_or(toks.len());
    toks[..end].join(" ")
}

fn extract_edition(lower: &str) -> Option<String> {
    const CHECKS: &[(&str, &str)] = &[
        ("directors cut", "Directors Cut"),
        ("directors.cut", "Directors Cut"),
        ("director's cut", "Directors Cut"),
        ("final cut", "Final Cut"),
        ("final.cut", "Final Cut"),
        ("special edition", "Special Edition"),
        ("extended", "Extended"),
        ("unrated", "Unrated"),
        ("remastered", "Remastered"),
        ("theatrical", "Theatrical"),
        ("uncut", "Uncut"),
        ("imax", "IMAX"),
    ];
    CHECKS
        .iter()
        .find(|(needle, _)| lower.contains(needle))
        .map(|(_, canon)| (*canon).to_string())
}

fn extract_languages(name: &str) -> Vec<String> {
    const MAP: &[(&str, &str)] = &[
        ("multi", "multi"),
        ("dual", "dual"),
        ("english", "en"),
        ("french", "fr"),
        ("vostfr", "fr"),
        ("spanish", "es"),
        ("german", "de"),
        ("italian", "it"),
        ("portuguese", "pt"),
        ("hindi", "hi"),
        ("japanese", "ja"),
        ("korean", "ko"),
        ("russian", "ru"),
        ("chinese", "zh"),
    ];
    let lower = name.to_ascii_lowercase();
    let mut out: Vec<String> = Vec::new();
    for tok in split_tokens(&lower) {
        if let Some((_, code)) = MAP.iter().find(|(n, _)| *n == tok) {
            if !out.iter().any(|c| c == code) {
                out.push((*code).to_string());
            }
        }
    }
    out
}

fn is_extension(tok: &str) -> bool {
    matches!(tok, "mkv" | "mp4" | "avi" | "mov" | "ts" | "m2ts" | "webm")
}

fn extract_group(name: &str) -> Option<String> {
    // Drop a trailing container extension so it is not mistaken for the group.
    let base = match name.rsplit_once('.') {
        Some((stem, ext)) if is_extension(&ext.to_ascii_lowercase()) => stem,
        _ => name,
    };
    let (_, after) = base.rsplit_once('-')?;
    // A bracket/space after the group (e.g. "GROUP[eztv]") ends it.
    let group = after.split(['[', '(', ' ']).next().unwrap_or(after).trim();
    if !group.is_empty() && group.len() <= 20 && group.chars().all(|c| c.is_ascii_alphanumeric()) {
        Some(group.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_movie_release() {
        let m = parse_release(
            "The.Movie.2024.2160p.UHD.BluRay.REMUX.DV.TrueHD.Atmos.7.1.HEVC-FraMeSToR",
        );
        assert_eq!(m.title, "The Movie");
        assert_eq!(m.year, Some(2024));
        assert_eq!(m.resolution, Resolution::P2160);
        assert_eq!(m.source_class, SourceClass::Remux);
        assert_eq!(m.hdr, Hdr::DolbyVision);
        assert_eq!(m.audio, Audio::Atmos);
        assert_eq!(m.codec.as_deref(), Some("x265"));
        assert_eq!(m.group.as_deref(), Some("FraMeSToR"));
        assert!(!m.proper && !m.repack);
    }

    #[test]
    fn series_release_with_group() {
        let m = parse_release("Show.S03E09.1080p.WEB-DL.DDP5.1.H.264-NTb");
        assert_eq!(m.title, "Show");
        assert_eq!(m.season, Some(3));
        assert_eq!(m.episode, Some(9));
        assert_eq!(m.group.as_deref(), Some("NTb"));
        assert_eq!(m.year, None);
    }

    #[test]
    fn edition_and_proper() {
        let m = parse_release("Film.2019.PROPER.Extended.1080p.BluRay.x265-DON");
        assert!(m.proper);
        assert_eq!(m.edition.as_deref(), Some("Extended"));
        assert_eq!(m.title, "Film");
    }

    #[test]
    fn languages_extracted() {
        let m = parse_release("Anime.S01E13.1080p.Multi.x265-Grp");
        assert_eq!(m.languages, vec!["multi".to_string()]);
    }

    #[test]
    fn title_without_markers_is_whole_name() {
        let m = parse_release("Just A Title");
        assert_eq!(m.title, "Just A Title");
        assert_eq!(m.group, None);
    }

    #[test]
    fn group_ignores_container_extension() {
        let m = parse_release("Movie.2020.1080p.BluRay.x264-GRP.mkv");
        assert_eq!(m.group.as_deref(), Some("GRP"));
    }
}
