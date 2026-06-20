//! The Stremio add-on `manifest.json`.
//!
//! An add-on advertises which `resources` (catalog / meta / stream / subtitles / addon_catalog)
//! it serves, for which `types` (movie / series / channel / tv / ...), and which `catalogs` it
//! exposes. VortX parses this exactly like the official clients so every existing add-on works.
//!
//! The `resources` field is polymorphic: an entry is EITHER a bare string (`"stream"`, applies to
//! all of the add-on's `types` and `idPrefixes`) OR an object that narrows the resource to specific
//! types / id-prefixes. We model that with an untagged enum and normalise on read.

use serde::{Deserialize, Serialize};

/// A parsed add-on manifest.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub id: String,
    pub version: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Resources the add-on serves. Each is a bare name or a narrowing object.
    #[serde(default)]
    pub resources: Vec<ManifestResource>,
    /// Content types the add-on handles (movie, series, channel, tv, ...).
    #[serde(default)]
    pub types: Vec<String>,
    /// Catalogs (the Discover/Board rows) the add-on exposes.
    #[serde(default)]
    pub catalogs: Vec<ManifestCatalog>,
    /// Add-on-catalog resource (an add-on that lists OTHER add-ons), rarely used.
    #[serde(
        default,
        rename = "addonCatalogs",
        skip_serializing_if = "Vec::is_empty"
    )]
    pub addon_catalogs: Vec<ManifestCatalog>,

    /// ID prefixes the add-on can answer for (e.g. `["tt"]` for IMDb ids). Empty = any.
    #[serde(
        default,
        rename = "idPrefixes",
        skip_serializing_if = "Option::is_none"
    )]
    pub id_prefixes: Option<Vec<String>>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub background: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub logo: Option<String>,
    #[serde(
        default,
        rename = "contactEmail",
        skip_serializing_if = "Option::is_none"
    )]
    pub contact_email: Option<String>,

    #[serde(
        default,
        rename = "behaviorHints",
        skip_serializing_if = "Option::is_none"
    )]
    pub behavior_hints: Option<ManifestBehaviorHints>,
}

/// A single entry in `manifest.resources`: a bare name, or a name narrowed to types/id-prefixes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ManifestResource {
    Short(String),
    Full {
        name: String,
        #[serde(default)]
        types: Vec<String>,
        #[serde(default, rename = "idPrefixes")]
        id_prefixes: Option<Vec<String>>,
    },
}

impl ManifestResource {
    /// The resource name regardless of which form was used.
    pub fn name(&self) -> &str {
        match self {
            ManifestResource::Short(name) => name,
            ManifestResource::Full { name, .. } => name,
        }
    }
}

/// One catalog row advertised by the add-on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestCatalog {
    #[serde(rename = "type")]
    pub type_: String,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Full-form extra props (`{ name, isRequired, options, optionsLimit }`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub extra: Vec<ManifestExtra>,
    /// Short-form supported extra prop names (older manifests).
    #[serde(
        default,
        rename = "extraSupported",
        skip_serializing_if = "Option::is_none"
    )]
    pub extra_supported: Option<Vec<String>>,
    /// Short-form required extra prop names (older manifests).
    #[serde(
        default,
        rename = "extraRequired",
        skip_serializing_if = "Option::is_none"
    )]
    pub extra_required: Option<Vec<String>>,
}

/// A catalog extra parameter (genre, search, skip, ...).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ManifestExtra {
    pub name: String,
    #[serde(default, rename = "isRequired")]
    pub is_required: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<String>>,
    #[serde(
        default,
        rename = "optionsLimit",
        skip_serializing_if = "Option::is_none"
    )]
    pub options_limit: Option<u32>,
}

/// Add-on-level behaviour flags.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ManifestBehaviorHints {
    #[serde(default)]
    pub adult: bool,
    #[serde(default)]
    pub p2p: bool,
    #[serde(default)]
    pub configurable: bool,
    #[serde(default, rename = "configurationRequired")]
    pub configuration_required: bool,
}

impl Manifest {
    /// Does this add-on serve `resource` for `type_` and `id`?
    ///
    /// Mirrors the official client's matching: the resource must be advertised, the type must be in
    /// the resource's `types` (or the manifest's `types` for the short form), and the id must match
    /// one of the resource's (or the manifest's) `idPrefixes` when any are declared.
    pub fn supports(&self, resource: &str, type_: &str, id: &str) -> bool {
        self.resources.iter().any(|r| {
            if r.name() != resource {
                return false;
            }
            let (types, id_prefixes) = match r {
                ManifestResource::Short(_) => (&self.types, &self.id_prefixes),
                ManifestResource::Full {
                    types, id_prefixes, ..
                } => (
                    if types.is_empty() { &self.types } else { types },
                    if id_prefixes.is_some() {
                        id_prefixes
                    } else {
                        &self.id_prefixes
                    },
                ),
            };
            let type_ok = types.is_empty() || types.iter().any(|t| t == type_);
            // idPrefixes constrain CONTENT ids (meta/stream/subtitles). Catalog ids (e.g. "top")
            // are catalog identifiers, not content ids, so the official clients do not gate catalog
            // or addon_catalog requests on idPrefixes.
            let id_gated = resource != "catalog" && resource != "addon_catalog";
            let id_ok = !id_gated
                || match id_prefixes {
                    Some(prefixes) if !prefixes.is_empty() => {
                        prefixes.iter().any(|p| id.starts_with(p))
                    }
                    _ => true,
                };
            type_ok && id_ok
        })
    }
}
