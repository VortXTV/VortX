//! A Stremio addon as a [`Source`]. `supports` delegates to the already-tested `Manifest::supports`; the
//! capability set is derived from the manifest's declared resources.

use vortx_addons::InstalledAddon;
use vortx_protocol::{ResourcePath, Stream};

use crate::request::{resource_to_kind, ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::transport::FetchRequest;
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

    fn plan(&self, req: &ResourceRequest, budget_ms: u64) -> Option<FetchRequest> {
        // Only plan a fetch this addon actually serves; the byte-exact Stremio transport URL is built
        // from the addon's transport URL (its id) plus the request path, so it resolves identically to
        // the official client. The host performs the GET; this stays pure.
        if !self.supports(req) {
            return None;
        }
        Some(FetchRequest {
            addon_id: self.id().to_string(),
            url: ResourcePath::from(req).to_url(self.id()),
            budget_ms,
        })
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // Direct blocking resolution is not the path: vortx_source::resolve_streams drives plan() through
        // the host Fetch boundary. This stays as the explicit "no in-kernel I/O" marker.
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
