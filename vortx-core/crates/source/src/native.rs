//! NativeVortx: the engine's FIRST-CLASS source kind, not an adapter. A native `vortx-source/1` source is
//! reached over HTTP with the byte-exact Stremio resource grammar (`/resource/type/id.json`), but it serves
//! a SIGNED manifest from `/manifest.vortx.json` (verified up front) and emits the typed `behaviorHints.vortx`
//! side-channel the ranker reads instead of parsing titles. This wraps a parsed VortxAddonManifest as a
//! [`Source`], so the registry routes and the orchestrator fans out to it exactly like any other source,
//! while the engine's privileged hooks (typed ranking, hive cache-check, prefetch) stay armed.

use vortx_protocol::{ResourcePath, Stream};

use crate::manifest::{VortxAddonManifest, VortxTransport};
use crate::request::{ResourceKind, ResourceRequest};
use crate::source::{Source, SourceKind};
use crate::transport::FetchRequest;
use crate::verify::{verify_manifest, ManifestVerification};
use crate::SourceError;

/// A first-class native VortX source backed by a `vortx-source/1` manifest.
pub struct NativeVortxSource {
    manifest: VortxAddonManifest,
    verification: ManifestVerification,
}

impl NativeVortxSource {
    /// Wrap a native manifest, verifying its signature ONCE up front. The verification status is recorded so
    /// the host/engine can apply its trust policy (e.g. consume only [`ManifestVerification::Valid`] sources
    /// in a strict mode); construction itself never fails, so an unsigned source is still usable but flagged.
    pub fn new(manifest: VortxAddonManifest) -> Self {
        let verification = verify_manifest(&manifest);
        Self {
            manifest,
            verification,
        }
    }

    /// The manifest's signature trust status (computed at construction).
    pub fn verification(&self) -> ManifestVerification {
        self.verification
    }

    pub fn manifest(&self) -> &VortxAddonManifest {
        &self.manifest
    }

    /// Whether the source promises typed score inputs (`ranking.emitsScoreInputs`), so the ranker trusts its
    /// `behaviorHints.vortx` over title tokens.
    pub fn emits_score_inputs(&self) -> bool {
        self.manifest
            .ranking
            .as_ref()
            .map(|r| r.emits_score_inputs)
            .unwrap_or(false)
    }
}

/// The HTTP base for a native source: strip the native (`/manifest.vortx.json`) or plain (`/manifest.json`)
/// manifest filename, else trim a trailing slash. `base_url` in `vortx-protocol` only strips `/manifest.json`,
/// so a native manifest URL needs this first or the resource path would be built under the manifest file.
fn native_base(manifest_url: &str) -> &str {
    manifest_url
        .strip_suffix("/manifest.vortx.json")
        .or_else(|| manifest_url.strip_suffix("/manifest.json"))
        .unwrap_or_else(|| manifest_url.trim_end_matches('/'))
}

impl Source for NativeVortxSource {
    fn id(&self) -> &str {
        &self.manifest.id
    }

    fn kind(&self) -> SourceKind {
        SourceKind::NativeVortx
    }

    fn capabilities(&self) -> &[ResourceKind] {
        &self.manifest.capabilities
    }

    fn supports(&self, req: &ResourceRequest) -> bool {
        if !self.manifest.capabilities.contains(&req.kind) {
            return false;
        }
        if !self.manifest.types.is_empty() && !self.manifest.types.contains(&req.type_) {
            return false;
        }
        // idPrefixes gate CONTENT ids only (catalog ids are addon-defined), mirroring the Stremio rule.
        let gates_id = matches!(
            req.kind,
            ResourceKind::Meta | ResourceKind::Stream | ResourceKind::Subtitles
        );
        if gates_id
            && !self.manifest.id_prefixes.is_empty()
            && !self
                .manifest
                .id_prefixes
                .iter()
                .any(|p| req.id.starts_with(p))
        {
            return false;
        }
        true
    }

    fn plan(&self, req: &ResourceRequest, budget_ms: u64) -> Option<FetchRequest> {
        if !self.supports(req) {
            return None;
        }
        // A native source is reached over HTTP with the byte-exact Stremio resource grammar; only the
        // manifest path differs (/manifest.vortx.json). Non-HTTP transports (Federated / Nuvio / Debrid)
        // resolve through a different host seam, not a plain GET, so they plan no fetch here.
        let base = match &self.manifest.transport {
            VortxTransport::StremioHttp { manifest_url } => native_base(manifest_url),
            _ => return None,
        };
        Some(FetchRequest {
            addon_id: self.id().to_string(),
            url: ResourcePath::from(req).to_url(base),
            budget_ms,
        })
    }

    fn resolve(&self, _req: &ResourceRequest) -> Result<Vec<Stream>, SourceError> {
        // Direct blocking resolution is not the path: vortx_source::resolve_streams drives plan() through the
        // host Fetch boundary, and the host parses the typed behaviorHints.vortx into Streams.
        Err(SourceError::NotImplemented)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::RankingCapability;

    fn native(caps: &[ResourceKind], types: &[&str], id_prefixes: &[&str]) -> VortxAddonManifest {
        let mut m = VortxAddonManifest::native(
            "tv.vortx.native.demo",
            "1.0.0",
            "Demo Native",
            VortxTransport::StremioHttp {
                manifest_url: "https://src.vortx.tv/manifest.vortx.json".into(),
            },
        );
        m.capabilities = caps.to_vec();
        m.types = types.iter().map(|t| t.to_string()).collect();
        m.id_prefixes = id_prefixes.iter().map(|p| p.to_string()).collect();
        m
    }

    #[test]
    fn plan_builds_the_typed_stream_url_stripping_the_native_manifest_suffix() {
        let s = NativeVortxSource::new(native(&[ResourceKind::Stream], &["movie"], &["tt"]));
        let req = ResourceRequest::new(ResourceKind::Stream, "movie", "tt0111161");
        let plan = s.plan(&req, 5000).unwrap();
        assert_eq!(plan.url, "https://src.vortx.tv/stream/movie/tt0111161.json");
        assert_eq!(plan.addon_id, "tv.vortx.native.demo");
        assert_eq!(plan.budget_ms, 5000);
    }

    #[test]
    fn supports_gates_capability_type_and_content_idprefix() {
        let s = NativeVortxSource::new(native(
            &[ResourceKind::Stream, ResourceKind::Meta],
            &["movie", "series"],
            &["tt"],
        ));
        assert!(s.supports(&ResourceRequest::new(ResourceKind::Stream, "movie", "tt1")));
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Stream, "movie", "kitsu:42"))); // id prefix
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Stream, "music", "tt1"))); // type
        assert!(!s.supports(&ResourceRequest::new(ResourceKind::Subtitles, "movie", "tt1"))); // capability
    }

    #[test]
    fn catalog_ids_are_not_gated_by_idprefixes() {
        // idPrefixes gate content ids, not catalog ids (which the addon defines).
        let s = NativeVortxSource::new(native(&[ResourceKind::Catalog], &["movie"], &["tt"]));
        let req = ResourceRequest::new(ResourceKind::Catalog, "movie", "top");
        assert!(s.supports(&req));
        assert_eq!(
            s.plan(&req, 5000).unwrap().url,
            "https://src.vortx.tv/catalog/movie/top.json"
        );
    }

    #[test]
    fn an_unsupported_request_plans_no_fetch() {
        let s = NativeVortxSource::new(native(&[ResourceKind::Stream], &["movie"], &["tt"]));
        assert!(s
            .plan(&ResourceRequest::new(ResourceKind::Stream, "movie", "kitsu:1"), 5000)
            .is_none());
    }

    #[test]
    fn a_non_http_transport_plans_no_fetch() {
        let mut m = native(&[ResourceKind::Stream], &["movie"], &["tt"]);
        m.transport = VortxTransport::Federated {
            endpoint: "peer://node".into(),
        };
        let s = NativeVortxSource::new(m);
        assert!(s
            .plan(&ResourceRequest::new(ResourceKind::Stream, "movie", "tt1"), 5000)
            .is_none());
    }

    #[test]
    fn emits_score_inputs_reads_the_manifest_capability() {
        let mut m = native(&[ResourceKind::Stream], &["movie"], &["tt"]);
        m.ranking = Some(RankingCapability {
            emits_score_inputs: true,
        });
        assert!(NativeVortxSource::new(m).emits_score_inputs());
        assert!(!NativeVortxSource::new(native(&[ResourceKind::Stream], &["movie"], &["tt"]))
            .emits_score_inputs());
    }

    #[test]
    fn kind_is_native_vortx() {
        let s = NativeVortxSource::new(native(&[ResourceKind::Stream], &[], &[]));
        assert_eq!(s.kind(), SourceKind::NativeVortx);
    }
}
