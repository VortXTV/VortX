//! Resource requests. A [`ResourceRequest`] is id-space aware and carries `profile_id` from the first
//! commit (profiles are first-class), so a source's `supports()` can reject by id prefix with no network.

use serde::{Deserialize, Serialize};
use vortx_protocol::ResourcePath;

/// The typed resources a source can serve. A superset of the Stremio resources (catalog/meta/stream/
/// subtitles/addon_catalog) plus VortX-native ones (ratings/artwork/music).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    Catalog,
    Meta,
    Stream,
    Subtitles,
    AddonCatalog,
    Ratings,
    Artwork,
    MusicCatalog,
    MusicStream,
    /// Serves theme/accent/palette packs (native only).
    Theme,
    /// Serves home/tab arrangements (native only).
    Layout,
    /// Serves wordmark/splash/icon overrides (native only).
    Branding,
}

impl ResourceKind {
    /// The wire token used in transport URLs (Stremio-compatible for the Stremio resources).
    pub fn wire(&self) -> &'static str {
        match self {
            ResourceKind::Catalog => "catalog",
            ResourceKind::Meta => "meta",
            ResourceKind::Stream => "stream",
            ResourceKind::Subtitles => "subtitles",
            ResourceKind::AddonCatalog => "addon_catalog",
            ResourceKind::Ratings => "ratings",
            ResourceKind::Artwork => "artwork",
            ResourceKind::MusicCatalog => "music_catalog",
            ResourceKind::MusicStream => "music_stream",
            ResourceKind::Theme => "theme",
            ResourceKind::Layout => "layout",
            ResourceKind::Branding => "branding",
        }
    }
}

/// Map a Stremio resource name to a [`ResourceKind`] for capability derivation.
pub(crate) fn resource_to_kind(name: &str) -> Option<ResourceKind> {
    match name {
        "catalog" => Some(ResourceKind::Catalog),
        "meta" => Some(ResourceKind::Meta),
        "stream" => Some(ResourceKind::Stream),
        "subtitles" => Some(ResourceKind::Subtitles),
        "addon_catalog" => Some(ResourceKind::AddonCatalog),
        _ => None,
    }
}

/// The shared id-space gate: whether a source declaring `capabilities` / `types` / `id_prefixes` can answer
/// `req`. The request kind must be a declared capability, the type must match (unless the source declares no
/// types = all), and `idPrefixes` gate CONTENT ids only (meta/stream/subtitles) since catalog ids are
/// addon-defined. Pure and cheap (no network). Used by every source that gates from flat capability lists
/// (the native source and the lightweight [`crate::SourceEntry`] snapshot).
pub(crate) fn id_space_allows(
    capabilities: &[ResourceKind],
    types: &[String],
    id_prefixes: &[String],
    req: &ResourceRequest,
) -> bool {
    if !capabilities.contains(&req.kind) {
        return false;
    }
    if !types.is_empty() && !types.contains(&req.type_) {
        return false;
    }
    let gates_id = matches!(
        req.kind,
        ResourceKind::Meta | ResourceKind::Stream | ResourceKind::Subtitles
    );
    if gates_id && !id_prefixes.is_empty() && !id_prefixes.iter().any(|p| req.id.starts_with(p)) {
        return false;
    }
    true
}

/// A request for a resource, scoped to a profile.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResourceRequest {
    pub kind: ResourceKind,
    #[serde(rename = "type")]
    pub type_: String,
    pub id: String,
    #[serde(default)]
    pub extra: Vec<(String, String)>,
    #[serde(default, rename = "profileId", skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
}

impl ResourceRequest {
    pub fn new(kind: ResourceKind, type_: impl Into<String>, id: impl Into<String>) -> Self {
        Self {
            kind,
            type_: type_.into(),
            id: id.into(),
            extra: Vec::new(),
            profile_id: None,
        }
    }

    pub fn with_extra(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.extra.push((key.into(), value.into()));
        self
    }

    pub fn for_profile(mut self, profile_id: impl Into<String>) -> Self {
        self.profile_id = Some(profile_id.into());
        self
    }
}

impl From<&ResourceRequest> for ResourcePath {
    /// Reuse the byte-exact Stremio transport grammar from `vortx-protocol`.
    fn from(req: &ResourceRequest) -> Self {
        let mut path = ResourcePath::new(req.kind.wire(), req.type_.clone(), req.id.clone());
        for (key, value) in &req.extra {
            path = path.with_extra(key.clone(), value.clone());
        }
        path
    }
}
