//! Season-pack / multi-file episode mapping. A torrent or debrid folder often holds a whole season (or a
//! whole series); [`map_episode`] resolves WHICH file is the requested episode, including anime absolute
//! numbering, and never selects a sample clip. It reuses [`crate::release::parse_release`] for the
//! per-file season/episode, so there is one parser. Pure, deterministic, total.

use serde::{Deserialize, Serialize};

use crate::release::parse_release;

const VIDEO_EXT: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "m4v", "ts", "m2ts", "webm", "flv", "wmv", "mpg", "mpeg",
];

/// One file inside a pack.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PackFile {
    pub index: u32,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
}

/// The episode being requested. A movie/single request leaves all three `None`. A series request gives
/// `season` + `episode`; an anime request may additionally (or only) give the `absolute` number.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct EpisodeRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub season: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub episode: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub absolute: Option<u32>,
}

/// How the file was matched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MatchKind {
    SeasonEpisode,
    Absolute,
    SingleVideo,
}

/// The resolved file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileMatch {
    pub index: u32,
    pub name: String,
    pub matched_by: MatchKind,
}

fn extension(name: &str) -> Option<&str> {
    name.rsplit_once('.')
        .map(|(_, e)| e)
        .filter(|e| !e.is_empty() && e.len() <= 5)
}

fn is_video(name: &str) -> bool {
    extension(name).is_some_and(|e| VIDEO_EXT.contains(&e.to_ascii_lowercase().as_str()))
}

fn is_sample(name: &str) -> bool {
    name.to_ascii_lowercase().contains("sample")
}

/// The absolute episode number from an anime-style filename (`[Grp] Show - 13 (1080p).mkv` -> 13). Looks
/// for the ` - <number>` separator that anime releases use. Returns `None` if no such number is present.
fn absolute_episode_of(name: &str) -> Option<u32> {
    let lower = name.to_ascii_lowercase();
    let pos = lower.find(" - ")?;
    let rest = lower[pos + 3..].trim_start();
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    digits
        .parse::<u32>()
        .ok()
        .filter(|n| (1..=9999).contains(n))
}

/// Convert a seasonal `(season, episode)` to an absolute episode number, given the episode counts of the
/// prior seasons (`prior_counts[i]` = episodes in season `i+1`). Lets the metadata layer feed the
/// `absolute` field of an [`EpisodeRequest`] for an absolute-numbered anime pack.
pub fn absolute_from_seasonal(season: u32, episode: u32, prior_counts: &[u32]) -> u32 {
    let before: u32 = prior_counts
        .iter()
        .take(season.saturating_sub(1) as usize)
        .sum();
    before + episode
}

/// Resolve the file in `files` that satisfies `request`. Returns `None` if nothing matches (never a
/// sample, never a non-video). Order of preference: exact season+episode, then absolute number; a movie /
/// single request (all fields `None`) returns the largest video file.
pub fn map_episode(files: &[PackFile], request: &EpisodeRequest) -> Option<FileMatch> {
    let mut videos: Vec<&PackFile> = files
        .iter()
        .filter(|f| is_video(&f.name) && !is_sample(&f.name))
        .collect();
    if videos.is_empty() {
        return None;
    }

    // Movie / single: the largest video file (tiebreak by lowest index).
    if request.season.is_none() && request.episode.is_none() && request.absolute.is_none() {
        videos.sort_by(|a, b| {
            b.size_bytes
                .unwrap_or(0)
                .cmp(&a.size_bytes.unwrap_or(0))
                .then(a.index.cmp(&b.index))
        });
        let f = videos[0];
        return Some(FileMatch {
            index: f.index,
            name: f.name.clone(),
            matched_by: MatchKind::SingleVideo,
        });
    }

    // Seasonal match (SxxExx in the filename).
    if let (Some(s), Some(e)) = (request.season, request.episode) {
        if let Some(f) = pick_lowest_index(&videos, |name| {
            let p = parse_release(name);
            p.season == Some(s) && p.episode == Some(e)
        }) {
            return Some(FileMatch {
                index: f.index,
                name: f.name.clone(),
                matched_by: MatchKind::SeasonEpisode,
            });
        }
    }

    // Absolute match (anime absolute numbering).
    if let Some(abs) = request.absolute {
        if let Some(f) = pick_lowest_index(&videos, |name| absolute_episode_of(name) == Some(abs)) {
            return Some(FileMatch {
                index: f.index,
                name: f.name.clone(),
                matched_by: MatchKind::Absolute,
            });
        }
    }

    None
}

/// The lowest-index file satisfying `pred` (deterministic on ties).
fn pick_lowest_index<'a>(
    videos: &[&'a PackFile],
    pred: impl Fn(&str) -> bool,
) -> Option<&'a PackFile> {
    videos
        .iter()
        .filter(|f| pred(&f.name))
        .min_by_key(|f| f.index)
        .copied()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(index: u32, name: &str, size: Option<u64>) -> PackFile {
        PackFile {
            index,
            name: name.into(),
            size_bytes: size,
        }
    }

    #[test]
    fn seasonal_pack_picks_the_right_episode() {
        let files = vec![
            file(0, "Show.S02E01.1080p.WEB-DL.mkv", None),
            file(1, "Show.S02E02.1080p.WEB-DL.mkv", None),
            file(2, "Show.S02E03.1080p.WEB-DL.mkv", None),
        ];
        let req = EpisodeRequest {
            season: Some(2),
            episode: Some(2),
            absolute: None,
        };
        let m = map_episode(&files, &req).unwrap();
        assert_eq!(m.index, 1);
        assert_eq!(m.matched_by, MatchKind::SeasonEpisode);
    }

    #[test]
    fn anime_absolute_maps_to_seasonal() {
        // S02E01 of a show whose season 1 had 12 episodes is absolute 13.
        let files = vec![
            file(0, "[SubsPlease] Show - 12 (1080p).mkv", None),
            file(1, "[SubsPlease] Show - 13 (1080p).mkv", None),
            file(2, "[SubsPlease] Show - 14 (1080p).mkv", None),
        ];
        let absolute = absolute_from_seasonal(2, 1, &[12]);
        assert_eq!(absolute, 13);
        let req = EpisodeRequest {
            season: Some(2),
            episode: Some(1),
            absolute: Some(absolute),
        };
        let m = map_episode(&files, &req).unwrap();
        assert_eq!(m.index, 1);
        assert_eq!(m.matched_by, MatchKind::Absolute);
    }

    #[test]
    fn movie_picks_largest_video_excluding_sample() {
        let files = vec![
            file(
                0,
                "Movie.2024.1080p.BluRay.x264-GRP.mkv",
                Some(8_000_000_000),
            ),
            file(1, "sample.mkv", Some(50_000_000)),
            file(2, "extras.mkv", Some(300_000_000)),
            file(3, "readme.nfo", None),
        ];
        let m = map_episode(&files, &EpisodeRequest::default()).unwrap();
        assert_eq!(m.index, 0);
        assert_eq!(m.matched_by, MatchKind::SingleVideo);
    }

    #[test]
    fn never_returns_a_sample_episode() {
        let files = vec![
            file(0, "Show.S01E01.sample.mkv", None),
            file(1, "Show.S01E01.1080p.mkv", None),
        ];
        let req = EpisodeRequest {
            season: Some(1),
            episode: Some(1),
            absolute: None,
        };
        let m = map_episode(&files, &req).unwrap();
        assert_eq!(m.index, 1); // the sample (index 0) is excluded
    }

    #[test]
    fn no_match_returns_none() {
        let files = vec![file(0, "Show.S01E01.mkv", None)];
        let req = EpisodeRequest {
            season: Some(5),
            episode: Some(9),
            absolute: None,
        };
        assert!(map_episode(&files, &req).is_none());
    }
}
