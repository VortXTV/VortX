//! A small, dependency-free NZB parser. NZB is a constrained XML dialect (nzb > file > groups/group +
//! segments/segment), so a focused tag scanner is enough and keeps the crate dependency-light and fully
//! conformance-pinnable. It is tolerant (a malformed file/segment is skipped, not fatal) and total (it
//! never panics on any input: every slice is taken at an ASCII tag boundary returned by `find`).

use crate::model::{Nzb, NzbFile, NzbSegment};

/// Why an NZB failed to parse.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum NzbError {
    /// No `<file>` elements were found (not a usable NZB).
    #[error("nzb has no <file> elements")]
    NoFiles,
}

/// Parse an NZB document into its files and segments. Unknown attributes and elements are ignored.
pub fn parse_nzb(xml: &str) -> Result<Nzb, NzbError> {
    let mut files = Vec::new();
    let mut idx = 0;
    while let Some(rel) = xml[idx..].find("<file") {
        let fstart = idx + rel;
        // Reject a longer tag name (e.g. a hypothetical `<filelist>`): the name must end here.
        if !tag_name_ends(&xml[fstart + "<file".len()..]) {
            idx = fstart + "<file".len();
            continue;
        }
        // The end of the opening tag.
        let Some(gt_rel) = xml[fstart..].find('>') else { break };
        let open_tag = &xml[fstart..fstart + gt_rel];
        let body_start = fstart + gt_rel + 1;
        // The matching close. A tolerant parser stops at the next </file>; if absent, take the rest.
        let (body_end, next) = match xml[body_start..].find("</file>") {
            Some(c) => (body_start + c, body_start + c + "</file>".len()),
            None => (xml.len(), xml.len()),
        };
        let body = &xml[body_start..body_end];

        files.push(NzbFile {
            subject: attr(open_tag, "subject").unwrap_or_default(),
            poster: attr(open_tag, "poster"),
            date: attr(open_tag, "date").and_then(|d| d.parse().ok()),
            groups: parse_groups(body),
            segments: parse_segments(body),
        });
        idx = next;
    }
    if files.is_empty() {
        return Err(NzbError::NoFiles);
    }
    Ok(Nzb { files })
}

fn parse_groups(body: &str) -> Vec<String> {
    let mut groups = Vec::new();
    let mut i = 0;
    while let Some(rel) = body[i..].find("<group>") {
        let start = i + rel + "<group>".len();
        let Some(end_rel) = body[start..].find("</group>") else { break };
        groups.push(unescape(body[start..start + end_rel].trim()));
        i = start + end_rel;
    }
    groups
}

fn parse_segments(body: &str) -> Vec<NzbSegment> {
    let mut segments = Vec::new();
    let mut i = 0;
    while let Some(rel) = body[i..].find("<segment") {
        let start = i + rel;
        // Reject `<segments>` (the container): the tag name must end after `<segment`.
        if !tag_name_ends(&body[start + "<segment".len()..]) {
            i = start + "<segment".len();
            continue;
        }
        let Some(gt_rel) = body[start..].find('>') else { break };
        let open = &body[start..start + gt_rel];
        let text_start = start + gt_rel + 1;
        let Some(end_rel) = body[text_start..].find("</segment>") else { break };
        let message_id = unescape(body[text_start..text_start + end_rel].trim());
        segments.push(NzbSegment {
            bytes: attr(open, "bytes").and_then(|b| b.parse().ok()).unwrap_or(0),
            number: attr(open, "number").and_then(|n| n.parse().ok()).unwrap_or(0),
            message_id,
        });
        i = text_start + end_rel;
    }
    segments
}

/// Read a quoted attribute value from an opening tag, unescaped. Matches `name` only when it is a whole
/// attribute name (preceded by whitespace or the tag start) followed by `=`.
fn attr(open_tag: &str, name: &str) -> Option<String> {
    let mut from = 0;
    while let Some(rel) = open_tag[from..].find(name) {
        let at = from + rel;
        let pre_ok = at == 0
            || open_tag[..at]
                .ends_with(|c: char| c.is_whitespace() || c == '<');
        let after = open_tag[at + name.len()..].trim_start();
        if pre_ok {
            if let Some(rest) = after.strip_prefix('=') {
                let val = rest.trim_start();
                if let Some(q) = val.strip_prefix(['"', '\'']) {
                    // The opening quote char is the same as the closing; recover it from `val`.
                    let quote = val.as_bytes()[0] as char;
                    if let Some(end) = q.find(quote) {
                        return Some(unescape(&q[..end]));
                    }
                }
            }
        }
        from = at + name.len();
    }
    None
}

/// Whether a tag name ends at the start of `after` (the next char closes the name: whitespace, `>`, or
/// `/`), so `<segment` does not match inside `<segments>`.
fn tag_name_ends(after: &str) -> bool {
    matches!(after.chars().next(), None | Some('>') | Some('/'))
        || after.starts_with(char::is_whitespace)
}

/// Unescape the five predefined XML entities. `&amp;` is replaced last so an escaped entity like
/// `&amp;lt;` decodes to the literal `&lt;`, not `<`.
fn unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version="1.0"?>
<nzb><file poster="p@x" date="1000" subject="movie.mkv (1/2)">
  <groups><group>alt.binaries.movies</group></groups>
  <segments>
    <segment bytes="500" number="1">a@news</segment>
    <segment bytes="400" number="2">b@news</segment>
  </segments>
</file></nzb>"#;

    #[test]
    fn parses_a_basic_nzb() {
        let nzb = parse_nzb(SAMPLE).unwrap();
        assert_eq!(nzb.files.len(), 1);
        let f = &nzb.files[0];
        assert_eq!(f.subject, "movie.mkv (1/2)");
        assert_eq!(f.poster.as_deref(), Some("p@x"));
        assert_eq!(f.date, Some(1000));
        assert_eq!(f.groups, vec!["alt.binaries.movies"]);
        assert_eq!(f.segments.len(), 2);
        assert_eq!(f.segments[0], NzbSegment { bytes: 500, number: 1, message_id: "a@news".into() });
        assert_eq!(f.total_bytes(), 900);
    }

    #[test]
    fn unescapes_entities_and_single_quotes() {
        let xml = r#"<nzb><file subject='a &amp; b'><segments><segment bytes="1" number="1">x&lt;y</segment></segments></file></nzb>"#;
        let nzb = parse_nzb(xml).unwrap();
        assert_eq!(nzb.files[0].subject, "a & b");
        assert_eq!(nzb.files[0].segments[0].message_id, "x<y");
    }

    #[test]
    fn no_files_is_an_error() {
        assert_eq!(parse_nzb("<nzb></nzb>"), Err(NzbError::NoFiles));
    }
}
