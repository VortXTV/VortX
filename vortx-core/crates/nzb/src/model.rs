//! The NZB data model and the per-file classification the retrieval policy reads. Pure data; the wire
//! shapes are the cross-language contract.

use serde::{Deserialize, Serialize};

/// One Usenet article segment of a file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NzbSegment {
    /// Article size in bytes (as declared in the NZB).
    pub bytes: u64,
    /// 1-based segment number; the streaming order within a file.
    pub number: u32,
    /// The Usenet message id (without angle brackets) the host fetches.
    pub message_id: String,
}

/// One file inside an NZB (a content file, or a par2 repair file).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NzbFile {
    /// The article subject. Carries the filename and usually a `(x/N)` yEnc part count.
    pub subject: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub poster: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub date: Option<u64>,
    #[serde(default)]
    pub groups: Vec<String>,
    #[serde(default)]
    pub segments: Vec<NzbSegment>,
}

impl NzbFile {
    /// Declared total size: the sum of the segment byte counts.
    pub fn total_bytes(&self) -> u64 {
        self.segments.iter().map(|s| s.bytes).sum()
    }

    /// Whether this is a par2 repair file (deferred until a repair is needed), by its subject.
    pub fn is_par2(&self) -> bool {
        self.subject.to_ascii_lowercase().contains(".par2")
    }

    /// The article count the subject claims via a trailing `(x/N)` marker, if present. Used for a
    /// completeness check without contacting a server.
    pub fn claimed_segments(&self) -> Option<u32> {
        parse_yenc_count(&self.subject)
    }

    /// How many segments are missing versus the claimed count (`0` when complete or the count is unknown).
    pub fn missing_segments(&self) -> u32 {
        match self.claimed_segments() {
            Some(claimed) => claimed.saturating_sub(self.segments.len() as u32),
            None => 0,
        }
    }

    /// Whether every claimed segment is present. Unknown count is treated as complete (we cannot prove it
    /// incomplete from the NZB alone).
    pub fn is_complete(&self) -> bool {
        self.missing_segments() == 0
    }
}

/// A parsed NZB: an ordered list of files.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Nzb {
    pub files: Vec<NzbFile>,
}

impl Nzb {
    pub fn total_bytes(&self) -> u64 {
        self.files.iter().map(NzbFile::total_bytes).sum()
    }

    pub fn segment_count(&self) -> usize {
        self.files.iter().map(|f| f.segments.len()).sum()
    }
}

/// Extract the `N` from the LAST `(x/N)` yEnc part marker in a subject, with both sides all-digits.
fn parse_yenc_count(subject: &str) -> Option<u32> {
    let mut result = None;
    let mut from = 0;
    while let Some(rel) = subject[from..].find('(') {
        let open = from + rel;
        if let Some(close_rel) = subject[open..].find(')') {
            let inside = &subject[open + 1..open + close_rel];
            if let Some((a, b)) = inside.split_once('/') {
                if !a.is_empty()
                    && !b.is_empty()
                    && a.bytes().all(|c| c.is_ascii_digit())
                    && b.bytes().all(|c| c.is_ascii_digit())
                {
                    if let Ok(n) = b.parse::<u32>() {
                        result = Some(n);
                    }
                }
            }
        }
        from = open + 1;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn yenc_count_takes_the_last_valid_marker() {
        assert_eq!(parse_yenc_count("Movie (2024) file.mkv (1/50)"), Some(50));
        assert_eq!(parse_yenc_count("no marker here"), None);
        assert_eq!(parse_yenc_count("(notnum/x)"), None);
    }

    #[test]
    fn par2_detection_and_completeness() {
        let par2 = NzbFile {
            subject: "x.vol00+1.PAR2 (1/1)".into(),
            poster: None,
            date: None,
            groups: vec![],
            segments: vec![NzbSegment { bytes: 1, number: 1, message_id: "a".into() }],
        };
        assert!(par2.is_par2());
        assert!(par2.is_complete());

        let short = NzbFile {
            subject: "movie.mkv (1/3)".into(),
            poster: None,
            date: None,
            groups: vec![],
            segments: vec![NzbSegment { bytes: 1, number: 1, message_id: "a".into() }],
        };
        assert!(!short.is_par2());
        assert_eq!(short.missing_segments(), 2);
        assert!(!short.is_complete());
    }
}
