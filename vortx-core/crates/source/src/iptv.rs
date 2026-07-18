//! IPTV as a first-class installed source. An Xtream panel or an M3U playlist is promoted into the
//! [`crate::SourceRegistry`] under [`SourceKind::Iptv`], so its VOD competes in the SAME ranked stream list as
//! a Stremio addon, a Nuvio provider, or a debrid result, with ZERO provider cooperation. The engine already
//! parses/ranks/resolves every source uniformly; this just makes IPTV one of them.
//!
//! An IPTV source answers over a plain host GET (like an HTTP addon), but its `vod_endpoint` is the raw
//! playlist / `get_vod_streams` URL, NOT a Stremio `/resource/type/id.json` path, so [`IptvSource::plan`]
//! (and the snapshot planner [`crate::plan_streams`]) fetch it as-is. The body the host gets back is M3U text
//! or Xtream VOD JSON; the pure `vortx_live` VOD mapping turns it into protocol streams that flow into the
//! normal settle -> rank path (`vortx_live::m3u_vod_to_streams` / `xtream_vod_to_streams`). The host holds the
//! Xtream credentials and builds the endpoint, so no secret ever enters the kernel.

use vortx_protocol::Stream;

use crate::request::{id_space_allows, ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::transport::FetchRequest;
use crate::SourceError;

/// An installed IPTV source (an Xtream panel or an M3U playlist) exposed as a [`Source`]. Holds only the
/// already-built VOD endpoint URL plus the id-space it answers; the credentials (for Xtream) live host-side,
/// baked into `vod_endpoint`, so this pure type never sees them.
pub struct IptvSource {
    id: String,
    vod_endpoint: String,
    capabilities: Vec<ResourceKind>,
    types: Vec<String>,
    id_prefixes: Vec<String>,
}

impl IptvSource {
    /// A general IPTV source: `id` is stable within the registry, `vod_endpoint` is the URL the host fetches
    /// for VOD (an M3U playlist URL or an Xtream `get_vod_streams` URL). Defaults to answering `stream` for
    /// `movie`, with no id-prefix constraint; refine with [`IptvSource::with_types`] / [`Self::with_id_prefixes`].
    pub fn new(id: impl Into<String>, vod_endpoint: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            vod_endpoint: vod_endpoint.into(),
            capabilities: vec![ResourceKind::Stream],
            types: vec!["movie".to_string()],
            id_prefixes: Vec::new(),
        }
    }

    /// Narrow the content types this source answers (default `["movie"]`).
    pub fn with_types(mut self, types: &[&str]) -> Self {
        self.types = types.iter().map(|t| t.to_string()).collect();
        self
    }

    /// Constrain the content id-prefixes this source answers (default: any).
    pub fn with_id_prefixes(mut self, prefixes: &[&str]) -> Self {
        self.id_prefixes = prefixes.iter().map(|p| p.to_string()).collect();
        self
    }

    /// The VOD endpoint the host fetches for this source.
    pub fn vod_endpoint(&self) -> &str {
        &self.vod_endpoint
    }
}

impl Source for IptvSource {
    fn id(&self) -> &str {
        &self.id
    }

    fn kind(&self) -> SourceKind {
        SourceKind::Iptv
    }

    fn capabilities(&self) -> &[ResourceKind] {
        &self.capabilities
    }

    fn supports(&self, req: &ResourceRequest) -> bool {
        id_space_allows(&self.capabilities, &self.types, &self.id_prefixes, req)
    }

    fn plan(&self, req: &ResourceRequest, budget_ms: u64) -> Option<FetchRequest> {
        if !self.supports(req) {
            return None;
        }
        // Unlike a Stremio addon, an IPTV source is fetched at its raw VOD endpoint (a playlist / get_vod_streams
        // URL), NOT a `/stream/type/id.json` resource path. The host parses the returned M3U/Xtream body into
        // protocol streams via the pure vortx_live VOD mapping.
        Some(FetchRequest {
            addon_id: self.id.clone(),
            url: self.vod_endpoint.clone(),
            budget_ms,
        })
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // Resolution drives plan() through the host Fetch boundary + the vortx_live VOD mapping, like every
        // other source; the pure layer never blocks.
        Err(SourceError::NotImplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stream_req(type_: &str, id: &str) -> ResourceRequest {
        ResourceRequest::new(ResourceKind::Stream, type_, id)
    }

    #[test]
    fn plans_a_fetch_to_the_raw_vod_endpoint_not_a_stremio_resource_path() {
        let src = IptvSource::new(
            "xtream:demo",
            "http://host:8080/player_api.php?username=u&password=p&action=get_vod_streams",
        );
        let plan = src.plan(&stream_req("movie", "tt1"), 5000).unwrap();
        assert_eq!(plan.addon_id, "xtream:demo");
        // The URL is the endpoint verbatim (no /stream/movie/tt1.json rewriting).
        assert_eq!(
            plan.url,
            "http://host:8080/player_api.php?username=u&password=p&action=get_vod_streams"
        );
        assert_eq!(plan.budget_ms, 5000);
    }

    #[test]
    fn kind_is_iptv_and_capabilities_include_stream() {
        let src = IptvSource::new("m3u:demo", "http://host/playlist.m3u");
        assert_eq!(src.kind(), SourceKind::Iptv);
        assert!(src.capabilities().contains(&ResourceKind::Stream));
    }

    #[test]
    fn supports_gates_type_and_id_prefix() {
        let src = IptvSource::new("x", "http://h/p.m3u")
            .with_types(&["movie"])
            .with_id_prefixes(&["tt"]);
        assert!(src.supports(&stream_req("movie", "tt1")));
        assert!(!src.supports(&stream_req("series", "tt1"))); // wrong type
        assert!(!src.supports(&stream_req("movie", "kitsu:1"))); // wrong id prefix
        // An unsupported request plans no fetch.
        assert!(src.plan(&stream_req("series", "tt1"), 5000).is_none());
    }

    #[test]
    fn installs_into_a_registry_and_is_routed_like_any_source() {
        use crate::registry::SourceRegistry;
        let mut reg = SourceRegistry::new();
        reg.install(Box::new(IptvSource::new("iptv", "http://h/vod").with_id_prefixes(&["tt"])));
        let hits = reg.resolve(&stream_req("movie", "tt1"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id(), "iptv");
        assert_eq!(hits[0].kind(), SourceKind::Iptv);
    }
}
