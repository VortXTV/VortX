//! Per-profile ranking preferences. The user's `source_type_order` is the TOP ranking key (an
//! anti-regression invariant), so an explicitly preferred source beats a higher-resolution non-preferred
//! one. These come from a profile's settings, so ranking is asked "for THIS profile", not a global mirror.

use serde::{Deserialize, Serialize};

use crate::parse::{Resolution, SourceClass};

/// What a profile prefers when ranking streams.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RankingPrefs {
    /// Source classes in preference order (first = most preferred). Non-empty makes preference the TOP
    /// ranking key. A source class not listed gets no preference bonus.
    #[serde(default)]
    pub source_type_order: Vec<SourceClass>,
    /// Float a debrid-cached stream to the top of its resolution tier (default on).
    #[serde(default = "default_true")]
    pub cached_first: bool,
    /// Preferred audio/subtitle languages (advisory; reserved for a later language weight).
    #[serde(default)]
    pub preferred_languages: Vec<String>,
    /// Drop streams above this resolution (e.g. a 720p-only device).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_resolution: Option<Resolution>,
    /// Drop streams whose known size exceeds this many GB.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_filesize_gb: Option<f64>,
    /// If non-empty, only keep streams whose label contains one of these keywords.
    #[serde(default)]
    pub keyword_include: Vec<String>,
    /// Drop streams whose label contains any of these keywords (anti-cam / fake-4k hygiene).
    #[serde(default)]
    pub keyword_exclude: Vec<String>,
}

fn default_true() -> bool {
    true
}

impl Default for RankingPrefs {
    fn default() -> Self {
        Self {
            source_type_order: Vec::new(),
            cached_first: true,
            preferred_languages: Vec::new(),
            max_resolution: None,
            max_filesize_gb: None,
            keyword_include: Vec::new(),
            keyword_exclude: Vec::new(),
        }
    }
}
