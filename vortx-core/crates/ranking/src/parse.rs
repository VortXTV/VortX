//! The release-token parser. Turns an add-on's free-text stream label (name + title + description) into
//! a structured [`ParsedData`]. The parser is the cross-language contract: the same label must parse to
//! the same tokens on every platform (pinned by conformance vectors), so ranking is consistent everywhere.

use serde::{Deserialize, Serialize};

/// Video resolution tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Resolution {
    #[serde(rename = "2160p")]
    P2160,
    #[serde(rename = "1080p")]
    P1080,
    #[serde(rename = "720p")]
    P720,
    #[serde(rename = "480p")]
    P480,
    Unknown,
}

impl Resolution {
    /// Ordering rank (higher is better), used for the max-resolution filter and the tier score.
    pub fn rank(self) -> u8 {
        match self {
            Resolution::P2160 => 4,
            Resolution::P1080 => 3,
            Resolution::P720 => 2,
            Resolution::P480 => 1,
            Resolution::Unknown => 0,
        }
    }
}

/// Source class, best to worst. Remux strictly beats a bigger web encode (the #68 fix).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceClass {
    Remux,
    BluRay,
    WebDl,
    Web,
    Hdtv,
    Cam,
    Unknown,
}

/// High-dynamic-range format.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Hdr {
    DolbyVision,
    Hdr10Plus,
    Hdr10,
    None,
}

/// Audio format, best to worst (advisory; carried to the player router).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Audio {
    Atmos,
    TrueHd,
    DtsHdMa,
    DdPlus,
    None,
}

/// Structured release tokens parsed from a stream label.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParsedData {
    pub resolution: Resolution,
    pub source_class: SourceClass,
    pub hdr: Hdr,
    pub audio: Audio,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub channels: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub codec: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    pub repack: bool,
    /// A fake / cam / upscaled source that must sink below all legit streams.
    pub junk: bool,
}

fn has(hay: &str, needle: &str) -> bool {
    hay.contains(needle)
}

/// Parse season/episode from an `sNNeNN` token in lowercased text.
fn parse_season_episode(text: &str) -> (Option<u32>, Option<u32>) {
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b's' {
            let mut j = i + 1;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            if j > i + 1 && j < bytes.len() && bytes[j] == b'e' {
                let mut k = j + 1;
                while k < bytes.len() && bytes[k].is_ascii_digit() {
                    k += 1;
                }
                if k > j + 1 {
                    let season = text[i + 1..j].parse().ok();
                    let episode = text[j + 1..k].parse().ok();
                    return (season, episode);
                }
            }
        }
        i += 1;
    }
    (None, None)
}

/// Parse a stream label (lowercased internally) into structured tokens.
pub fn parse(label: &str) -> ParsedData {
    let t = label.to_ascii_lowercase();

    let resolution = if has(&t, "2160") || has(&t, "4k") || has(&t, "uhd") {
        Resolution::P2160
    } else if has(&t, "1080") {
        Resolution::P1080
    } else if has(&t, "720") {
        Resolution::P720
    } else if has(&t, "480") {
        Resolution::P480
    } else {
        Resolution::Unknown
    };

    let source_class = if has(&t, "remux") {
        SourceClass::Remux
    } else if has(&t, "bluray") || has(&t, "blu-ray") || has(&t, "bdrip") || has(&t, "brrip") {
        SourceClass::BluRay
    } else if has(&t, "web-dl") || has(&t, "webdl") || has(&t, "web dl") {
        SourceClass::WebDl
    } else if has(&t, "webrip") || has(&t, "web") {
        SourceClass::Web
    } else if has(&t, "hdtv") {
        SourceClass::Hdtv
    } else if has(&t, "hdcam") || has(&t, "cam") || has(&t, "telesync") || has(&t, "hdts") {
        SourceClass::Cam
    } else {
        SourceClass::Unknown
    };

    let hdr = if has(&t, "dolby vision") || has(&t, "dovi") || has(&t, " dv ") || has(&t, ".dv.") {
        Hdr::DolbyVision
    } else if has(&t, "hdr10+") || has(&t, "hdr10plus") {
        Hdr::Hdr10Plus
    } else if has(&t, "hdr") {
        Hdr::Hdr10
    } else {
        Hdr::None
    };

    let audio = if has(&t, "atmos") {
        Audio::Atmos
    } else if has(&t, "truehd") || has(&t, "true-hd") {
        Audio::TrueHd
    } else if has(&t, "dts-hd") || has(&t, "dts hd") || has(&t, "dtshd") {
        Audio::DtsHdMa
    } else if has(&t, "dd+") || has(&t, "ddp") || has(&t, "eac3") || has(&t, "e-ac-3") {
        Audio::DdPlus
    } else {
        Audio::None
    };

    let channels = ["7.1", "5.1", "2.0"]
        .into_iter()
        .find(|c| has(&t, c))
        .map(str::to_string);

    let codec = if has(&t, "x265") || has(&t, "h265") || has(&t, "hevc") || has(&t, "h.265") {
        Some("x265".to_string())
    } else if has(&t, "x264") || has(&t, "h264") || has(&t, "h.264") || has(&t, "avc") {
        Some("h264".to_string())
    } else if has(&t, "av1") {
        Some("av1".to_string())
    } else {
        None
    };

    let (season, episode) = parse_season_episode(&t);
    let repack = has(&t, "repack") || has(&t, "proper");
    let junk = has(&t, "fake") || has(&t, "upscale") || source_class == SourceClass::Cam;

    ParsedData {
        resolution,
        source_class,
        hdr,
        audio,
        channels,
        codec,
        season,
        episode,
        repack,
        junk,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_rich_remux_label() {
        let p =
            parse("The Movie 2024 2160p UHD BluRay REMUX Dolby Vision TrueHD Atmos 7.1 HEVC-GROUP");
        assert_eq!(p.resolution, Resolution::P2160);
        assert_eq!(p.source_class, SourceClass::Remux);
        assert_eq!(p.hdr, Hdr::DolbyVision);
        assert_eq!(p.audio, Audio::Atmos);
        assert_eq!(p.channels.as_deref(), Some("7.1"));
        assert_eq!(p.codec.as_deref(), Some("x265"));
        assert!(!p.junk);
    }

    #[test]
    fn parses_series_web_dl() {
        let p = parse("Show S03E09 1080p WEB-DL DDP5.1 H.264");
        assert_eq!(p.resolution, Resolution::P1080);
        assert_eq!(p.source_class, SourceClass::WebDl);
        assert_eq!(p.audio, Audio::DdPlus);
        assert_eq!(p.season, Some(3));
        assert_eq!(p.episode, Some(9));
        assert_eq!(p.codec.as_deref(), Some("h264"));
    }

    #[test]
    fn cam_is_junk() {
        let p = parse("Movie 2024 HDCAM 720p");
        assert_eq!(p.source_class, SourceClass::Cam);
        assert!(p.junk);
    }

    #[test]
    fn fake_is_junk() {
        assert!(parse("Movie 2160p FAKE 4k upscaled").junk);
    }

    #[test]
    fn unknown_when_no_tokens() {
        let p = parse("Just A Title");
        assert_eq!(p.resolution, Resolution::Unknown);
        assert_eq!(p.source_class, SourceClass::Unknown);
        assert_eq!(p.hdr, Hdr::None);
    }
}
