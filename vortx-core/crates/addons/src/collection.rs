//! The installed-add-on collection: the ordered set of add-ons the user has added, each with its
//! parsed manifest and VortX-side flags. Install order is priority order, so the first-installed
//! stream add-on is tried first when the router aggregates results.

use serde::{Deserialize, Serialize};
use vortx_protocol::Manifest;

/// VortX-side flags tracked per installed add-on (mirrors Stremio's collection descriptor flags).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AddonFlags {
    /// Shipped or endorsed by VortX (Cinemeta, the Singularity hub, ...). Surfaced differently and
    /// not removed by a plain "reset add-ons".
    #[serde(default)]
    pub official: bool,
    /// User-protected: kept across a reset.
    #[serde(default)]
    pub protected: bool,
}

/// An add-on the user has installed: its transport URL (the `manifest.json` URL), the parsed
/// manifest, and VortX flags.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InstalledAddon {
    #[serde(rename = "transportUrl")]
    pub transport_url: String,
    pub manifest: Manifest,
    #[serde(default)]
    pub flags: AddonFlags,
}

impl InstalledAddon {
    /// A freshly installed add-on with default (unflagged) status.
    pub fn new(transport_url: impl Into<String>, manifest: Manifest) -> Self {
        Self {
            transport_url: transport_url.into(),
            manifest,
            flags: AddonFlags::default(),
        }
    }

    /// Set the flags (chainable).
    pub fn with_flags(mut self, flags: AddonFlags) -> Self {
        self.flags = flags;
        self
    }
}

/// The ordered set of installed add-ons. Install order is priority order: the router and the
/// aggregators preserve it, so the user's first-installed source add-on is tried first.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct AddonCollection {
    addons: Vec<InstalledAddon>,
}

impl AddonCollection {
    /// An empty collection.
    pub fn new() -> Self {
        Self::default()
    }

    /// A collection from an existing ordered list (priority = order).
    pub fn from_vec(addons: Vec<InstalledAddon>) -> Self {
        Self { addons }
    }

    /// Install an add-on. Idempotent by transport URL: re-installing replaces the existing entry in
    /// place (e.g. a refreshed manifest) so its priority position is stable, rather than duplicating.
    pub fn install(&mut self, addon: InstalledAddon) {
        if let Some(slot) = self
            .addons
            .iter_mut()
            .find(|a| a.transport_url == addon.transport_url)
        {
            *slot = addon;
        } else {
            self.addons.push(addon);
        }
    }

    /// Remove an add-on by transport URL. Returns `true` if one was removed.
    pub fn remove(&mut self, transport_url: &str) -> bool {
        let before = self.addons.len();
        self.addons.retain(|a| a.transport_url != transport_url);
        self.addons.len() != before
    }

    /// The installed add-on with this transport URL, if any.
    pub fn get(&self, transport_url: &str) -> Option<&InstalledAddon> {
        self.addons
            .iter()
            .find(|a| a.transport_url == transport_url)
    }

    /// Iterate the add-ons in priority (install) order.
    pub fn iter(&self) -> impl Iterator<Item = &InstalledAddon> {
        self.addons.iter()
    }

    /// Number of installed add-ons.
    pub fn len(&self) -> usize {
        self.addons.len()
    }

    /// Whether no add-ons are installed.
    pub fn is_empty(&self) -> bool {
        self.addons.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_protocol::parse_manifest;

    fn manifest(id: &str) -> Manifest {
        parse_manifest(&format!(
            r#"{{ "id": "{id}", "version": "1.0.0", "name": "{id}",
                  "resources": ["stream"], "types": ["movie"] }}"#
        ))
        .expect("manifest parses")
    }

    #[test]
    fn install_is_idempotent_by_transport_url_and_keeps_position() {
        let mut c = AddonCollection::new();
        c.install(InstalledAddon::new(
            "https://a/manifest.json",
            manifest("a"),
        ));
        c.install(InstalledAddon::new(
            "https://b/manifest.json",
            manifest("b"),
        ));
        assert_eq!(c.len(), 2);

        // Re-install "a" (e.g. an updated manifest) -> replaces in place, no duplicate, order stable.
        c.install(
            InstalledAddon::new("https://a/manifest.json", manifest("a")).with_flags(AddonFlags {
                official: true,
                protected: false,
            }),
        );
        assert_eq!(c.len(), 2);
        assert_eq!(
            c.iter().next().unwrap().transport_url,
            "https://a/manifest.json"
        );
        assert!(c.get("https://a/manifest.json").unwrap().flags.official);
    }

    #[test]
    fn remove_reports_whether_it_removed() {
        let mut c = AddonCollection::new();
        c.install(InstalledAddon::new(
            "https://a/manifest.json",
            manifest("a"),
        ));
        assert!(c.remove("https://a/manifest.json"));
        assert!(!c.remove("https://a/manifest.json"));
        assert!(c.is_empty());
    }

    #[test]
    fn installed_addon_flags_round_trip_through_serde() {
        let addon =
            InstalledAddon::new("https://a/manifest.json", manifest("a")).with_flags(AddonFlags {
                official: true,
                protected: true,
            });
        let json = serde_json::to_string(&addon).expect("serializes");
        let back: InstalledAddon = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(addon, back);
        assert!(back.flags.protected);
        // The wire key is camelCase so a persisted collection matches the Stremio/JSON shape.
        assert!(json.contains("\"transportUrl\""));
    }
}
