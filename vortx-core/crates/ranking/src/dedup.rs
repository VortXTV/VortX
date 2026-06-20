//! Cross-source dedup. Many addons surface the SAME release; this collapses the duplicates into one
//! [`MergedStream`] (with provenance) so the user sees each real choice once. Union-find over a
//! conservative merge predicate: exact `infohash + file_idx` always merges (literally the same torrent
//! file); otherwise a full release-signature match (year / season / episode / resolution / source /
//! group, via [`crate::release::parse_release`]) gated by a Levenshtein title similarity and a size
//! tolerance. Different group or resolution stays separate, so genuinely distinct encodes are preserved.
//! The partition is connected-components, hence order-independent and deterministic.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::release::parse_release;

/// Minimum normalized title similarity (Levenshtein ratio) to consider two labels the same title.
const TITLE_THRESHOLD: f64 = 0.85;
/// Max size difference, as a percent of the larger, for two copies to be the same release.
const SIZE_TOLERANCE_PCT: u64 = 10;

/// A stream candidate to dedup (the fields dedup needs from a ranked stream).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DedupStream {
    /// The addon/source that supplied this copy.
    pub source_id: String,
    /// The raw release label.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub infohash: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub file_idx: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size_bytes: Option<u64>,
}

/// A merged group of duplicate streams.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergedStream {
    /// The representative member (lowest input index).
    pub primary: usize,
    /// All input indices in this group, ascending.
    pub members: Vec<usize>,
    /// The distinct sources that carried this release, sorted.
    pub provenance: Vec<String>,
}

fn normalize_title(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .map(|c| c.to_ascii_lowercase())
        .collect()
}

fn levenshtein(a: &[u8], b: &[u8]) -> usize {
    let (n, m) = (a.len(), b.len());
    if n == 0 {
        return m;
    }
    if m == 0 {
        return n;
    }
    let mut prev: Vec<usize> = (0..=m).collect();
    let mut cur = vec![0usize; m + 1];
    for i in 1..=n {
        cur[0] = i;
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[m]
}

/// Levenshtein similarity ratio in `[0,1]` over alphanumeric-normalized titles.
fn title_similarity(a: &str, b: &str) -> f64 {
    let (na, nb) = (normalize_title(a), normalize_title(b));
    let max_len = na.len().max(nb.len());
    if max_len == 0 {
        return 1.0;
    }
    let dist = levenshtein(na.as_bytes(), nb.as_bytes());
    1.0 - (dist as f64 / max_len as f64)
}

fn size_within_tolerance(x: u64, y: u64) -> bool {
    let (lo, hi) = (x.min(y), x.max(y));
    hi == 0 || (hi - lo) * 100 <= hi * SIZE_TOLERANCE_PCT
}

fn should_merge(a: &DedupStream, b: &DedupStream) -> bool {
    // Literally the same torrent file.
    if let (Some(ha), Some(hb)) = (&a.infohash, &b.infohash) {
        if ha.eq_ignore_ascii_case(hb) && a.file_idx == b.file_idx {
            return true;
        }
    }
    let (pa, pb) = (parse_release(&a.name), parse_release(&b.name));
    let signature_match = pa.year == pb.year
        && pa.season == pb.season
        && pa.episode == pb.episode
        && pa.resolution == pb.resolution
        && pa.source_class == pb.source_class
        && pa.group == pb.group;
    if !signature_match || title_similarity(&pa.title, &pb.title) < TITLE_THRESHOLD {
        return false;
    }
    match (a.size_bytes, b.size_bytes) {
        (Some(x), Some(y)) => size_within_tolerance(x, y),
        _ => true,
    }
}

fn uf_find(parent: &mut [usize], mut x: usize) -> usize {
    while parent[x] != x {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    x
}

fn uf_union(parent: &mut [usize], a: usize, b: usize) {
    let (ra, rb) = (uf_find(parent, a), uf_find(parent, b));
    if ra != rb {
        parent[ra.max(rb)] = ra.min(rb);
    }
}

/// Collapse duplicate streams into merged groups. Order-independent and deterministic.
pub fn dedup(streams: &[DedupStream]) -> Vec<MergedStream> {
    let n = streams.len();
    let mut parent: Vec<usize> = (0..n).collect();
    for i in 0..n {
        for j in (i + 1)..n {
            if should_merge(&streams[i], &streams[j]) {
                uf_union(&mut parent, i, j);
            }
        }
    }

    let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
    for i in 0..n {
        let root = uf_find(&mut parent, i);
        groups.entry(root).or_default().push(i);
    }

    let mut out: Vec<MergedStream> = groups
        .values()
        .map(|members| {
            let mut members = members.clone();
            members.sort_unstable();
            let mut provenance: Vec<String> = members
                .iter()
                .map(|&m| streams[m].source_id.clone())
                .collect();
            provenance.sort();
            provenance.dedup();
            MergedStream {
                primary: members[0],
                members,
                provenance,
            }
        })
        .collect();
    out.sort_by(|a, b| a.members.cmp(&b.members));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(source: &str, name: &str, infohash: Option<&str>, size: Option<u64>) -> DedupStream {
        DedupStream {
            source_id: source.into(),
            name: name.into(),
            infohash: infohash.map(String::from),
            file_idx: infohash.map(|_| 0),
            size_bytes: size,
        }
    }

    #[test]
    fn exact_infohash_merges_across_sources() {
        let streams = vec![
            s(
                "torrentio",
                "The Movie 2024 1080p WEB-DL x264-GRP",
                Some("aabb"),
                Some(2_000_000_000),
            ),
            s(
                "comet",
                "The.Movie.2024.1080p.WEB-DL.x264-GRP",
                Some("AABB"),
                Some(2_000_000_000),
            ),
        ];
        let out = dedup(&streams);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].members, vec![0, 1]);
        assert_eq!(out[0].provenance, vec!["comet", "torrentio"]);
    }

    #[test]
    fn different_resolution_stays_separate() {
        let streams = vec![
            s(
                "a",
                "Movie 2024 1080p BluRay x264-GRP",
                None,
                Some(1_000_000_000),
            ),
            s(
                "b",
                "Movie 2024 2160p BluRay x264-GRP",
                None,
                Some(4_000_000_000),
            ),
        ];
        assert_eq!(dedup(&streams).len(), 2);
    }

    #[test]
    fn different_group_stays_separate() {
        let streams = vec![
            s(
                "a",
                "Movie 2024 1080p BluRay x264-AAA",
                None,
                Some(1_000_000_000),
            ),
            s(
                "b",
                "Movie 2024 1080p BluRay x264-BBB",
                None,
                Some(1_000_000_000),
            ),
        ];
        assert_eq!(dedup(&streams).len(), 2);
    }

    #[test]
    fn same_release_two_addons_merges() {
        let streams = vec![
            s(
                "a",
                "Show S01E01 1080p WEB-DL x264-NTb",
                None,
                Some(1_500_000_000),
            ),
            s(
                "b",
                "Show.S01E01.1080p.WEB-DL.x264-NTb",
                None,
                Some(1_550_000_000),
            ),
        ];
        assert_eq!(dedup(&streams).len(), 1);
    }

    #[test]
    fn size_mismatch_blocks_fuzzy_merge() {
        let streams = vec![
            s(
                "a",
                "Movie 2024 1080p BluRay x264-GRP",
                None,
                Some(1_000_000_000),
            ),
            s(
                "b",
                "Movie 2024 1080p BluRay x264-GRP",
                None,
                Some(5_000_000_000),
            ),
        ];
        assert_eq!(dedup(&streams).len(), 2);
    }
}
