//! Manifest validation: structural rules a malformed customization manifest must fail (archetype
//! exclusivity), plus advisory warnings (layout referential integrity, theme contrast). Pure; returns
//! structured [`Issue`]s the SDK, CLI, and app can render identically. Errors block; warnings inform.

use crate::manifest::VortxAddonManifest;
use crate::request::ResourceKind;

/// Severity of a validation finding. An `Error` makes the manifest invalid; a `Warning` is advisory.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Error,
    Warning,
}

use serde::{Deserialize, Serialize};

/// A single validation finding: where, what, and how serious.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Issue {
    pub path: String,
    pub code: String,
    pub severity: Severity,
}

/// Content-delivery resource kinds. A manifest carrying any of these is a content addon and may not also
/// carry a customization block.
const CONTENT_KINDS: &[ResourceKind] = &[
    ResourceKind::Catalog,
    ResourceKind::Meta,
    ResourceKind::Stream,
    ResourceKind::Subtitles,
    ResourceKind::MusicCatalog,
    ResourceKind::MusicStream,
];

/// Built-in home surfaces a layout rail may reference besides a real catalog key.
const BUILTIN_SURFACES: &[&str] = &[
    "continueWatching",
    "topPicks",
    "liveTV",
    "search",
    "recentlyAdded",
    "trending",
];

/// The known tab ids a layout may show/hide/reorder.
const KNOWN_TABS: &[&str] = &[
    "home", "discover", "library", "liveTV", "search", "settings",
];

/// Minimum WCAG contrast ratio for primary text on the canvas before a warning is emitted.
const MIN_CONTRAST: f64 = 4.5;

/// Validate a manifest. Returns every finding; an empty vec (or warnings-only, see [`has_errors`]) means
/// the manifest is structurally acceptable. Never panics.
pub fn validate(manifest: &VortxAddonManifest) -> Vec<Issue> {
    let mut issues = Vec::new();

    let Some(cust) = &manifest.customization else {
        return issues; // a pure content/source manifest: nothing customization-specific to check
    };

    // Archetype exclusivity: a manifest cannot be both a content source and a customization addon.
    if manifest
        .capabilities
        .iter()
        .any(|k| CONTENT_KINDS.contains(k))
    {
        issues.push(Issue {
            path: "customization".into(),
            code: "mixed_archetype".into(),
            severity: Severity::Error,
        });
    }

    // Layout referential integrity (advisory): a rail/tab pointing at an unknown surface drops with a
    // warning rather than crashing the board build.
    if let Some(layout) = &cust.layout {
        for rail in &layout.home.rails {
            if !is_known_surface(&rail.source) {
                issues.push(Issue {
                    path: format!("customization.layout.home.rails.{}", rail.id),
                    code: "unknown_surface".into(),
                    severity: Severity::Warning,
                });
            }
        }
        for tab in &layout.tabs {
            if !KNOWN_TABS.contains(&tab.id.as_str()) {
                issues.push(Issue {
                    path: format!("customization.layout.tabs.{}", tab.id),
                    code: "unknown_tab".into(),
                    severity: Severity::Warning,
                });
            }
        }
    }

    // Theme contrast (advisory): primary text must stand out on the canvas.
    for theme in &cust.themes {
        if let Some(palette) = &theme.palette {
            if let Some(text) = &palette.text_primary {
                // Canvas luminance: true black under the OLED modifier, else a near-black dark default.
                let canvas_lum = if theme.oled == Some(true) { 0.0 } else { 0.03 };
                if contrast_ratio(text.relative_luminance(), canvas_lum) < MIN_CONTRAST {
                    issues.push(Issue {
                        path: format!("customization.themes.{}.palette.textPrimary", theme.id),
                        code: "low_contrast".into(),
                        severity: Severity::Warning,
                    });
                }
            }
        }
    }

    issues
}

/// Whether any finding is an [`Severity::Error`] (the manifest is invalid).
pub fn has_errors(issues: &[Issue]) -> bool {
    issues.iter().any(|i| i.severity == Severity::Error)
}

fn is_known_surface(source: &str) -> bool {
    BUILTIN_SURFACES.contains(&source) || is_catalog_key(source)
}

/// A `base|type|id` catalog key: three non-empty pipe-separated parts.
fn is_catalog_key(s: &str) -> bool {
    let parts: Vec<&str> = s.split('|').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty())
}

fn contrast_ratio(l1: f64, l2: f64) -> f64 {
    let (hi, lo) = if l1 >= l2 { (l1, l2) } else { (l2, l1) };
    (hi + 0.05) / (lo + 0.05)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::customization::{AccentDef, Color, CustomizationCapability, ThemeDef};
    use crate::manifest::VortxAddonManifest;
    use crate::request::ResourceKind;
    use crate::VortxTransport;

    fn accent() -> AccentDef {
        AccentDef {
            base: Color::Srgb {
                r: 31,
                g: 111,
                b: 235,
                a: 255,
            },
            bright: Color::Srgb {
                r: 79,
                g: 155,
                b: 255,
                a: 255,
            },
        }
    }

    fn theme_manifest() -> VortxAddonManifest {
        let mut m = VortxAddonManifest::native(
            "tv.vortx.theme.midnight",
            "1.0.0",
            "Midnight",
            VortxTransport::Federated {
                endpoint: "local".into(),
            },
        );
        m.customization = Some(CustomizationCapability {
            provides_themes: true,
            themes: vec![ThemeDef {
                id: "midnight".into(),
                label: "Midnight".into(),
                accent: accent(),
                oled: Some(true),
                palette: None,
                radius: None,
                motion: None,
            }],
            ..CustomizationCapability::default()
        });
        m
    }

    #[test]
    fn clean_theme_manifest_has_no_errors() {
        let issues = validate(&theme_manifest());
        assert!(!has_errors(&issues), "expected no errors, got {issues:?}");
    }

    #[test]
    fn customization_plus_content_resource_is_a_mixed_archetype_error() {
        let mut m = theme_manifest();
        m.capabilities.push(ResourceKind::Stream);
        let issues = validate(&m);
        assert!(has_errors(&issues));
        assert!(issues.iter().any(|i| i.code == "mixed_archetype"));
    }

    #[test]
    fn lifted_stremio_manifest_validates_clean() {
        // A pure content manifest (no customization) has nothing to flag.
        let m = VortxAddonManifest::native(
            "x",
            "1",
            "X",
            VortxTransport::StremioHttp {
                manifest_url: "https://x/manifest.json".into(),
            },
        );
        assert!(validate(&m).is_empty());
    }
}
