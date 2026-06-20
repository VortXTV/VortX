//! A Nuvio provider as a [`Source`]. The actual stream production happens by running the provider's JS
//! and mapping with `vortx_adapters::scraper_streams_to_protocol` (the engine phase); this wrapper exposes
//! the provider's capability + id-space gate.

use vortx_adapters::ScraperInfo;
use vortx_protocol::Stream;

use crate::request::{ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::SourceError;

/// Wraps a Nuvio provider (from the repo manifest). Nuvio providers serve streams.
pub struct NuvioProviderSource {
    info: ScraperInfo,
    capabilities: Vec<ResourceKind>,
}

impl NuvioProviderSource {
    pub fn new(info: ScraperInfo) -> Self {
        Self {
            info,
            capabilities: vec![ResourceKind::Stream],
        }
    }
}

impl Source for NuvioProviderSource {
    fn id(&self) -> &str {
        &self.info.id
    }

    fn kind(&self) -> SourceKind {
        SourceKind::NuvioProvider
    }

    fn capabilities(&self) -> &[ResourceKind] {
        &self.capabilities
    }

    fn supports(&self, req: &ResourceRequest) -> bool {
        self.info.enabled
            && req.kind == ResourceKind::Stream
            && (self.info.supported_types.is_empty()
                || self.info.supported_types.contains(&req.type_))
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // The JS provider runtime that produces NuvioStreams is a later phase; the mapping it feeds into
        // is vortx_adapters::scraper_streams_to_protocol.
        Err(SourceError::NotImplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(enabled: bool, types: &[&str]) -> ScraperInfo {
        ScraperInfo {
            id: "vidrock".into(),
            name: "VidRock".into(),
            version: Some("1.0".into()),
            supported_types: types.iter().map(|t| t.to_string()).collect(),
            enabled,
        }
    }

    #[test]
    fn supports_stream_for_a_supported_type() {
        let s = NuvioProviderSource::new(info(true, &["movie", "tv"]));
        assert!(s.supports(&ResourceRequest::new(ResourceKind::Stream, "movie", "tt1")));
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Stream, "music", "x")));
        // not a stream request
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Meta, "movie", "tt1")));
    }

    #[test]
    fn disabled_provider_supports_nothing() {
        let s = NuvioProviderSource::new(info(false, &["movie"]));
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Stream, "movie", "tt1")));
    }
}
