//! A Stremio addon as a [`Source`]. `supports` delegates to the already-tested `Manifest::supports`; the
//! capability set is derived from the manifest's declared resources.

use vortx_addons::InstalledAddon;
use vortx_protocol::Stream;

use crate::request::{resource_to_kind, ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::SourceError;

/// Wraps an installed Stremio addon. Every existing addon (Cinemeta, Torrentio, AIOStreams, Comet,
/// MediaFusion, XRDB, ...) plugs in through this with no new code.
pub struct StremioAddonSource {
    addon: InstalledAddon,
    capabilities: Vec<ResourceKind>,
}

impl StremioAddonSource {
    pub fn new(addon: InstalledAddon) -> Self {
        let capabilities = addon
            .manifest
            .resources
            .iter()
            .filter_map(|r| resource_to_kind(r.name()))
            .collect();
        Self {
            addon,
            capabilities,
        }
    }
}

impl Source for StremioAddonSource {
    fn id(&self) -> &str {
        &self.addon.transport_url
    }

    fn kind(&self) -> SourceKind {
        SourceKind::StremioAddon
    }

    fn capabilities(&self) -> &[ResourceKind] {
        &self.capabilities
    }

    fn supports(&self, req: &ResourceRequest) -> bool {
        self.capabilities.contains(&req.kind)
            && self
                .addon
                .manifest
                .supports(req.kind.wire(), &req.type_, &req.id)
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // The HTTP transport (fetch + decode) lands in the engine I/O phase.
        Err(SourceError::NotImplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vortx_addons::InstalledAddon;
    use vortx_protocol::parse_manifest;

    fn cinemeta() -> InstalledAddon {
        let m = parse_manifest(
            r#"{ "id": "com.linvo.cinemeta", "version": "3.0.0", "name": "Cinemeta",
                 "resources": ["catalog", { "name": "meta", "types": ["movie", "series"], "idPrefixes": ["tt"] }],
                 "types": ["movie", "series"], "idPrefixes": ["tt"] }"#,
        )
        .unwrap();
        InstalledAddon::new("https://v3-cinemeta.strem.io/manifest.json", m)
    }

    #[test]
    fn derives_capabilities_from_resources() {
        let s = StremioAddonSource::new(cinemeta());
        assert!(s.capabilities().contains(&ResourceKind::Catalog));
        assert!(s.capabilities().contains(&ResourceKind::Meta));
        assert!(!s.capabilities().contains(&ResourceKind::Stream));
    }

    #[test]
    fn supports_gates_by_resource_and_idprefix_without_network() {
        let s = StremioAddonSource::new(cinemeta());
        assert!(s.supports(&ResourceRequest::new(
            ResourceKind::Meta,
            "movie",
            "tt0111161"
        )));
        // wrong id prefix is rejected by the capability gate (no network).
        assert!(!s.supports(&ResourceRequest::new(
            ResourceKind::Meta,
            "movie",
            "kitsu:42"
        )));
        // a resource it does not serve.
        assert!(!s.supports(&ResourceRequest::new(
            ResourceKind::Stream,
            "movie",
            "tt0111161"
        )));
    }
}
