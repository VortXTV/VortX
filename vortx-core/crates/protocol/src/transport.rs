//! Transport URLs: turning an add-on's `manifest.json` URL plus a resource request into the exact
//! HTTP URL the add-on expects.
//!
//! A Stremio add-on is identified by its TRANSPORT URL, which always ends in `/manifest.json`. A
//! resource is fetched from:
//!
//! ```text
//! {base}/{resource}/{type}/{id}.json                    (no extra)
//! {base}/{resource}/{type}/{id}/{extra}.json            (with extra)
//! ```
//!
//! where `base` is the transport URL minus the trailing `/manifest.json`, and `id`, `type`, and the
//! extra key/value pairs are each encoded with `encodeURIComponent` semantics. The extra segment is
//! `name=value` pairs joined by `&` (each name and value encoded), matching the official clients so
//! requests resolve identically to Stremio.

use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};

/// `encodeURIComponent` encode set: everything except `A-Za-z0-9` and `- _ . ! ~ * ' ( )`.
const COMPONENT: &AsciiSet = &NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'_')
    .remove(b'.')
    .remove(b'!')
    .remove(b'~')
    .remove(b'*')
    .remove(b'\'')
    .remove(b'(')
    .remove(b')');

fn enc(value: &str) -> String {
    utf8_percent_encode(value, COMPONENT).to_string()
}

/// The transport-URL base for an add-on: its `manifest.json` URL without the trailing file.
/// Returns the input unchanged (minus any trailing slash) if it does not end in `/manifest.json`,
/// so a base URL passed by mistake still works.
pub fn base_url(transport_url: &str) -> &str {
    transport_url
        .strip_suffix("/manifest.json")
        .unwrap_or_else(|| transport_url.trim_end_matches('/'))
}

/// A resource request against an add-on (before it is turned into a URL).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourcePath {
    pub resource: String,
    pub type_: String,
    pub id: String,
    /// Ordered extra key/value pairs (genre, search, skip, ...). Empty for a plain request.
    pub extra: Vec<(String, String)>,
}

impl ResourcePath {
    pub fn new(
        resource: impl Into<String>,
        type_: impl Into<String>,
        id: impl Into<String>,
    ) -> Self {
        Self {
            resource: resource.into(),
            type_: type_.into(),
            id: id.into(),
            extra: Vec::new(),
        }
    }

    /// Add one extra parameter (chainable).
    pub fn with_extra(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra.push((name.into(), value.into()));
        self
    }

    /// Encode the extra pairs into the single `name=value&name2=value2` path segment.
    fn extra_segment(&self) -> String {
        self.extra
            .iter()
            .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
            .collect::<Vec<_>>()
            .join("&")
    }

    /// Build the full resource URL given an add-on transport (or base) URL.
    pub fn to_url(&self, transport_url: &str) -> String {
        let base = base_url(transport_url);
        let head = format!(
            "{}/{}/{}/{}",
            base,
            enc(&self.resource),
            enc(&self.type_),
            enc(&self.id)
        );
        if self.extra.is_empty() {
            format!("{head}.json")
        } else {
            format!("{head}/{}.json", self.extra_segment())
        }
    }
}
