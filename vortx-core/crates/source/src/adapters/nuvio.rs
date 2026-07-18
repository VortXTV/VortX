//! A Nuvio provider as a [`Source`]. The provider's stream production is JS: the kernel PLANS the
//! execution here ([`Source::plan_exec`], a pinned-script [`ExecRequest`]), the HOST runs it behind the
//! `vortx_exec::JsExec` boundary, and the outcome's stream array maps through
//! `vortx_adapters::scraper_streams_to_protocol` into the same settle/rank path as an HTTP addon.

use vortx_adapters::ScraperInfo;
use vortx_exec::{stream_args_json, ExecRequest, NetPolicy, ENTRYPOINT_GET_STREAMS};
use vortx_protocol::Stream;

use crate::request::{ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::SourceError;

/// Wraps a Nuvio provider (from the repo manifest). Nuvio providers serve streams by running their
/// provider script; `script_hash` pins the exact source the host installed, and `permissions` are the
/// pack's declared manifest grants (deriving the [`NetPolicy`] its executions run under).
pub struct NuvioProviderSource {
    info: ScraperInfo,
    capabilities: Vec<ResourceKind>,
    script_hash: Option<String>,
    permissions: Vec<String>,
}

impl NuvioProviderSource {
    pub fn new(info: ScraperInfo) -> Self {
        Self {
            info,
            capabilities: vec![ResourceKind::Stream],
            script_hash: None,
            permissions: Vec::new(),
        }
    }

    /// Pin the provider's script by sha256 (hex). Without a pin the provider can never be
    /// exec-planned: the kernel refuses to orchestrate a script it cannot name by digest.
    pub fn with_script(mut self, script_hash: impl Into<String>) -> Self {
        self.script_hash = Some(script_hash.into());
        self
    }

    /// Attach the pack's declared manifest permissions (`net:<host>` grants network access).
    pub fn with_permissions(mut self, permissions: Vec<String>) -> Self {
        self.permissions = permissions;
        self
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

    fn plan_exec(&self, req: &ResourceRequest, budget_ms: u64) -> Option<ExecRequest> {
        // The plan path: a supported stream request on a pinned provider becomes a deterministic
        // ExecRequest (script by digest, getStreams entrypoint, stable args, manifest-derived net
        // policy). PURE: the host runs it; the kernel only decides what to run and under what policy.
        if !self.supports(req) {
            return None;
        }
        let script_hash = self.script_hash.clone()?;
        Some(ExecRequest {
            provider_id: self.info.id.clone(),
            script_hash,
            entrypoint: ENTRYPOINT_GET_STREAMS.to_string(),
            args_json: stream_args_json(&req.type_, &req.id),
            budget_ms,
            net_policy: NetPolicy::from_permissions(&self.permissions),
        })
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // Direct blocking resolution is not the path (same as StremioAddonSource): the engine drives
        // plan_exec() through the host JsExec boundary and settles the outcome. This stays as the
        // explicit "no in-kernel JS execution" marker.
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

    #[test]
    fn a_pinned_provider_plans_a_deterministic_exec_request() {
        let s = NuvioProviderSource::new(info(true, &["movie"]))
            .with_script("ab12")
            .with_permissions(vec!["net:api.vidrock.example".into(), "hive:contribute".into()]);
        let req = ResourceRequest::new(ResourceKind::Stream, "movie", "tt0111161");
        let plan = s.plan_exec(&req, 4000).expect("planned");
        assert_eq!(plan.provider_id, "vidrock");
        assert_eq!(plan.script_hash, "ab12");
        assert_eq!(plan.entrypoint, "getStreams");
        assert_eq!(plan.args_json, r#"["tt0111161","movie"]"#);
        assert_eq!(plan.budget_ms, 4000);
        // Only net:* permissions reach the policy.
        assert_eq!(plan.net_policy.host_allowlist, vec!["api.vidrock.example"]);
    }

    #[test]
    fn an_unpinned_or_unsupported_provider_plans_nothing() {
        // No script hash -> no plan (the kernel never orchestrates an unpinned script).
        let unpinned = NuvioProviderSource::new(info(true, &["movie"]));
        assert!(unpinned
            .plan_exec(&ResourceRequest::new(ResourceKind::Stream, "movie", "tt1"), 4000)
            .is_none());
        // Unsupported type -> routed out by the same gate as supports().
        let pinned = NuvioProviderSource::new(info(true, &["movie"])).with_script("ab");
        assert!(pinned
            .plan_exec(&ResourceRequest::new(ResourceKind::Stream, "music", "x"), 4000)
            .is_none());
    }
}
