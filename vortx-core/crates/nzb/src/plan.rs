//! The NZB retrieval and health POLICY: the pure decisions that make Usenet streaming good, with the
//! actual NNTP fetch left to the host. Two pieces:
//!
//! - [`health`]: a server-free completeness read from the NZB itself (segment counts vs the `(x/N)` yEnc
//!   claims), so a download manager can reject an obviously incomplete NZB before spending a request.
//! - [`retrieval_order`]: content first (in file order, segments by number = byte order = stream order),
//!   par2 repair files DEFERRED to the tail. The 10x over a naive "download every article" fetch is that
//!   par2 blocks are only pulled when a content segment is actually missing or fails, so a healthy
//!   download never wastes bandwidth on repair data it does not need.

use serde::{Deserialize, Serialize};

use crate::model::Nzb;

/// A server-free health summary of an NZB.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NzbHealth {
    pub total_bytes: u64,
    pub segment_count: usize,
    pub content_files: usize,
    pub par2_files: usize,
    /// True when every file with a known `(x/N)` claim has all its segments present.
    pub complete: bool,
    /// Sum of missing segments across files whose claimed count exceeds the segments present.
    pub missing_segments: u32,
}

/// Read the NZB's health without contacting a server.
pub fn health(nzb: &Nzb) -> NzbHealth {
    let mut content_files = 0;
    let mut par2_files = 0;
    let mut missing = 0u32;
    for f in &nzb.files {
        if f.is_par2() {
            par2_files += 1;
        } else {
            content_files += 1;
        }
        missing = missing.saturating_add(f.missing_segments());
    }
    NzbHealth {
        total_bytes: nzb.total_bytes(),
        segment_count: nzb.segment_count(),
        content_files,
        par2_files,
        complete: missing == 0,
        missing_segments: missing,
    }
}

/// One article to fetch, in retrieval order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RetrievalStep {
    pub message_id: String,
    pub bytes: u64,
    /// True for par2 repair articles (the deferred tail), false for content.
    pub is_repair: bool,
}

/// Build the streaming retrieval order: all content articles first (file order; segments sorted by their
/// number so a single file streams in byte order), then every par2 article. A host that streams in this
/// order can begin playback on the first content bytes and only reach the repair tail if it needs it.
pub fn retrieval_order(nzb: &Nzb) -> Vec<RetrievalStep> {
    let mut content = Vec::new();
    let mut repair = Vec::new();
    for f in &nzb.files {
        let is_repair = f.is_par2();
        let mut segs: Vec<_> = f.segments.iter().collect();
        segs.sort_by_key(|s| s.number);
        let target = if is_repair { &mut repair } else { &mut content };
        for s in segs {
            target.push(RetrievalStep {
                message_id: s.message_id.clone(),
                bytes: s.bytes,
                is_repair,
            });
        }
    }
    content.extend(repair);
    content
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parse_nzb;

    const SAMPLE: &str = r#"<nzb>
<file subject="movie.mkv (1/2)"><segments>
  <segment bytes="500" number="2">b@news</segment>
  <segment bytes="400" number="1">a@news</segment>
</segments></file>
<file subject="movie.vol00+1.par2 (1/1)"><segments>
  <segment bytes="100" number="1">p@news</segment>
</segments></file>
</nzb>"#;

    #[test]
    fn health_counts_content_and_par2() {
        let h = health(&parse_nzb(SAMPLE).unwrap());
        assert_eq!(h.total_bytes, 1000);
        assert_eq!(h.segment_count, 3);
        assert_eq!(h.content_files, 1);
        assert_eq!(h.par2_files, 1);
        assert!(h.complete);
        assert_eq!(h.missing_segments, 0);
    }

    #[test]
    fn retrieval_is_content_first_segments_in_number_order_par2_last() {
        let order = retrieval_order(&parse_nzb(SAMPLE).unwrap());
        let ids: Vec<&str> = order.iter().map(|s| s.message_id.as_str()).collect();
        // content file segments sorted by number (a=1 before b=2), then the par2 article.
        assert_eq!(ids, vec!["a@news", "b@news", "p@news"]);
        assert!(order[2].is_repair);
        assert!(!order[0].is_repair);
    }
}
