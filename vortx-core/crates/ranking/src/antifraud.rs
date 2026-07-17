//! Anti-fraud stream validation. The engine-level fix for the whole fake-stream class: drop executable
//! / trap / sample files, implausible size-per-minute, and mislabeled resolution (the "fake 4K" #68 bug)
//! BEFORE the user ever sees the stream. [`validate`] runs a fixed-order gauntlet of cheap pure checks,
//! first-match-wins, so the verdict is deterministic and monotone in evidence (a new fraud signal can
//! only move a stream toward Drop, never back to Keep). Size math is integer bytes-per-minute, no floats.

use serde::{Deserialize, Serialize};

use crate::release::parse_release;
use crate::Resolution;

/// Container/video extensions a playable file may have.
const VIDEO_EXT: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "m4v", "ts", "m2ts", "webm", "flv", "wmv", "mpg", "mpeg", "vob",
    "ogv",
];
/// Executable / script extensions that must never appear in a media torrent.
const BAD_EXT: &[&str] = &[
    "exe", "lnk", "scr", "bat", "cmd", "com", "pif", "msi", "vbs", "js", "jar", "apk", "dmg",
];

/// Implausibly large encode: above this bytes-per-minute, the size cannot be a real video.
const MAX_BYTES_PER_MIN: u64 = 2_000_000_000; // 2 GB/min (above any real 4K remux)
/// Implausibly small: below this, it is a fake / decoy.
const MIN_BYTES_PER_MIN: u64 = 1_000_000; // 1 MB/min

/// The minimum plausible bytes-per-minute for a claimed resolution (mislabel guard).
fn resolution_floor(res: Resolution) -> Option<u64> {
    match res {
        Resolution::P2160 => Some(20_000_000), // real 4K is well above this even compressed
        Resolution::P1080 => Some(6_000_000),
        Resolution::P720 => Some(2_000_000),
        Resolution::P480 | Resolution::Unknown => None,
    }
}

/// What the filter knows about a candidate stream.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct AntiFraudInput {
    /// The release label (parsed for the claimed resolution).
    #[serde(default)]
    pub name: String,
    /// File names inside the torrent (for extension / sample / trap detection).
    #[serde(default)]
    pub files: Vec<String>,
    /// Total or selected-file size in bytes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
    /// The title's runtime in minutes (from meta).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub runtime_minutes: Option<u32>,
}

/// Why a stream was dropped.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DropReason {
    /// An executable file, or no video file at all.
    NonVideoFile,
    /// Only sample clips are present.
    SampleFile,
    /// A password/decoy/link trap.
    Trap,
    /// Far too large to be a real video of this runtime.
    SizePerMinuteTooHigh,
    /// Far too small (fake / decoy).
    SizePerMinuteTooLow,
    /// Claims a resolution its size cannot support (fake 4K/HDR).
    MislabeledResolution,
}

/// Keep the stream, or drop it with a reason.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "verdict", rename_all = "snake_case")]
pub enum Verdict {
    Keep,
    Drop { reason: DropReason },
}

impl Verdict {
    fn drop(reason: DropReason) -> Self {
        Verdict::Drop { reason }
    }

    pub fn is_keep(&self) -> bool {
        matches!(self, Verdict::Keep)
    }
}

fn extension_of(file: &str) -> Option<&str> {
    file.rsplit_once('.')
        .map(|(_, ext)| ext)
        .filter(|ext| !ext.is_empty() && ext.len() <= 5)
}

/// Validate a candidate stream. First failing check wins; the order is frozen for determinism.
pub fn validate(input: &AntiFraudInput) -> Verdict {
    let files: Vec<String> = input.files.iter().map(|f| f.to_ascii_lowercase()).collect();

    // 1. Any executable file is an instant drop (a media torrent never contains one).
    if files
        .iter()
        .any(|f| extension_of(f).is_some_and(|e| BAD_EXT.contains(&e)))
    {
        return Verdict::drop(DropReason::NonVideoFile);
    }

    // 2. Decoy / link traps.
    if files
        .iter()
        .any(|f| f.contains("password") || extension_of(f) == Some("url"))
    {
        return Verdict::drop(DropReason::Trap);
    }

    // 3 + 4. File-set checks when the file list is known.
    if !files.is_empty() {
        let video: Vec<&String> = files
            .iter()
            .filter(|f| extension_of(f).is_some_and(|e| VIDEO_EXT.contains(&e)))
            .collect();
        if video.is_empty() {
            return Verdict::drop(DropReason::NonVideoFile);
        }
        if video.iter().all(|f| f.contains("sample")) {
            return Verdict::drop(DropReason::SampleFile);
        }
    }

    // 5-7. Size-per-minute sanity + mislabel guard.
    if let (Some(size), Some(runtime)) = (input.size_bytes, input.runtime_minutes) {
        if runtime > 0 {
            let bytes_per_min = size / runtime as u64;
            if bytes_per_min > MAX_BYTES_PER_MIN {
                return Verdict::drop(DropReason::SizePerMinuteTooHigh);
            }
            if bytes_per_min < MIN_BYTES_PER_MIN {
                return Verdict::drop(DropReason::SizePerMinuteTooLow);
            }
            if let Some(floor) = resolution_floor(parse_release(&input.name).resolution) {
                if bytes_per_min < floor {
                    return Verdict::drop(DropReason::MislabeledResolution);
                }
            }
        }
    }

    Verdict::Keep
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(
        name: &str,
        files: &[&str],
        size: Option<u64>,
        runtime: Option<u32>,
    ) -> AntiFraudInput {
        AntiFraudInput {
            name: name.into(),
            files: files.iter().map(|s| s.to_string()).collect(),
            size_bytes: size,
            runtime_minutes: runtime,
        }
    }

    #[test]
    fn keeps_a_normal_1080p_movie() {
        let i = input(
            "Movie 2024 1080p BluRay x264-GRP",
            &["movie.2024.1080p.bluray.x264-grp.mkv"],
            Some(3_000_000_000),
            Some(120),
        );
        assert!(validate(&i).is_keep());
    }

    #[test]
    fn drops_executable() {
        let i = input("Movie 2024 1080p", &["setup.exe", "readme.txt"], None, None);
        assert_eq!(validate(&i), Verdict::drop(DropReason::NonVideoFile));
    }

    #[test]
    fn drops_sample_only() {
        let i = input("Movie 2024 1080p", &["movie-sample.mkv"], None, None);
        assert_eq!(validate(&i), Verdict::drop(DropReason::SampleFile));
    }

    #[test]
    fn drops_password_trap() {
        let i = input("Movie", &["password.txt", "movie.mkv"], None, None);
        assert_eq!(validate(&i), Verdict::drop(DropReason::Trap));
    }

    #[test]
    fn drops_absurd_size() {
        // 90 GB for a 22-minute episode.
        let i = input(
            "Show S01E01 1080p",
            &["ep.mkv"],
            Some(90_000_000_000),
            Some(22),
        );
        assert_eq!(
            validate(&i),
            Verdict::drop(DropReason::SizePerMinuteTooHigh)
        );
    }

    #[test]
    fn drops_tiny_fake() {
        let i = input(
            "Movie 2024 1080p",
            &["movie.mkv"],
            Some(30_000_000),
            Some(120),
        );
        assert_eq!(validate(&i), Verdict::drop(DropReason::SizePerMinuteTooLow));
    }

    #[test]
    fn drops_fake_4k() {
        // Claims 2160p but only ~2.5 MB/min: cannot be real 4K.
        let i = input(
            "Movie 2024 2160p",
            &["movie.mkv"],
            Some(300_000_000),
            Some(120),
        );
        assert_eq!(
            validate(&i),
            Verdict::drop(DropReason::MislabeledResolution)
        );
    }
}
