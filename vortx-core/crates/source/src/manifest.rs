//! The native VortX addon manifest (`vortx-source/1`): a strict superset of the Stremio manifest. It keeps
//! every Stremio field (so lifting an existing addon is lossless) and adds the engine-native capabilities
//! the one-shot JSON protocol cannot express.

use serde::{Deserialize, Serialize};
use vortx_adapters::NuvioRepoManifest;
use vortx_addons::InstalledAddon;

use crate::request::{resource_to_kind, ResourceKind};
use crate::source::SourceKind;

/// The native manifest schema tag.
pub const NATIVE_SCHEMA: &str = "vortx-source/1";

/// How the engine reaches a source.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum VortxTransport {
    /// A standard Stremio HTTP addon (every existing addon).
    StremioHttp { manifest_url: String },
    /// A Nuvio providers repo (the JS scrapers are fetched from here).
    NuvioRepo { base_url: String },
    /// A federated peer VortX/hive node.
    Federated { endpoint: String },
    /// A debrid store, addressed by service.
    Debrid { service: vortx_hive::DebridService },
}

/// Declares the source returns infohashes so results route straight into the debrid vault.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct DebridCapability {
    #[serde(default, rename = "yieldsInfohash")]
    pub yields_infohash: bool,
    /// Who verifies cached status: `self` | `hive` | `engine`.
    #[serde(
        default,
        rename = "cachedCheck",
        skip_serializing_if = "Option::is_none"
    )]
    pub cached_check: Option<String>,
}

/// Declares hive (federated cache-fact) participation.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct HiveCapability {
    #[serde(default)]
    pub contributes: bool,
    #[serde(default)]
    pub consumes: bool,
    #[serde(
        default,
        rename = "factTtlSec",
        skip_serializing_if = "Option::is_none"
    )]
    pub fact_ttl_sec: Option<u64>,
}

/// Declares the source emits structured ranking features instead of a name string.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct RankingCapability {
    #[serde(default, rename = "emitsScoreInputs")]
    pub emits_score_inputs: bool,
}

/// Declares the configuration scope (e.g. `per-profile`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigCapability {
    pub scope: String,
}

/// A detached ed25519 signature over the canonical manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ManifestSignature {
    pub alg: String,
    #[serde(rename = "keyId")]
    pub key_id: String,
    pub sig: String,
}

/// The native VortX addon manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VortxAddonManifest {
    pub schema: String,
    pub id: String,
    pub version: String,
    pub name: String,
    pub kind: SourceKind,
    #[serde(default)]
    pub capabilities: Vec<ResourceKind>,
    #[serde(default)]
    pub types: Vec<String>,
    #[serde(default, rename = "idPrefixes")]
    pub id_prefixes: Vec<String>,
    pub transport: VortxTransport,

    // Engine-native capability flags (a Stremio addon leaves these at their defaults).
    #[serde(default)]
    pub streaming: bool,
    #[serde(default)]
    pub prefetch: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub debrid: Option<DebridCapability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hive: Option<HiveCapability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ranking: Option<RankingCapability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<ConfigCapability>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trust: Option<String>,
    #[serde(default)]
    pub permissions: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature: Option<ManifestSignature>,
}

impl VortxAddonManifest {
    /// A bare native manifest with all engine hooks off (the base every lift starts from).
    fn base(
        id: String,
        version: String,
        name: String,
        kind: SourceKind,
        transport: VortxTransport,
    ) -> Self {
        Self {
            schema: NATIVE_SCHEMA.to_string(),
            id,
            version,
            name,
            kind,
            capabilities: Vec::new(),
            types: Vec::new(),
            id_prefixes: Vec::new(),
            transport,
            streaming: false,
            prefetch: Vec::new(),
            debrid: None,
            hive: None,
            ranking: None,
            config: None,
            trust: None,
            permissions: Vec::new(),
            signature: None,
        }
    }
}

impl From<&InstalledAddon> for VortxAddonManifest {
    /// Lift an installed Stremio addon to the native manifest, losslessly, as `kind = stremio_addon`.
    fn from(addon: &InstalledAddon) -> Self {
        let m = &addon.manifest;
        let capabilities = m
            .resources
            .iter()
            .filter_map(|r| resource_to_kind(r.name()))
            .collect();
        let mut out = Self::base(
            m.id.clone(),
            m.version.clone(),
            m.name.clone(),
            SourceKind::StremioAddon,
            VortxTransport::StremioHttp {
                manifest_url: addon.transport_url.clone(),
            },
        );
        out.capabilities = capabilities;
        out.types = m.types.clone();
        out.id_prefixes = m.id_prefixes.clone().unwrap_or_default();
        out
    }
}

impl From<&NuvioRepoManifest> for VortxAddonManifest {
    /// Lift a Nuvio providers repo to the native manifest as `kind = nuvio_provider`.
    fn from(repo: &NuvioRepoManifest) -> Self {
        let base_url = repo.base_url.clone().unwrap_or_default();
        let mut out = Self::base(
            repo.base_url
                .clone()
                .unwrap_or_else(|| "nuvio-repo".to_string()),
            repo.version.clone().unwrap_or_else(|| "0".to_string()),
            "Nuvio Providers".to_string(),
            SourceKind::NuvioProvider,
            VortxTransport::NuvioRepo { base_url },
        );
        out.capabilities = vec![ResourceKind::Stream];
        out
    }
}
