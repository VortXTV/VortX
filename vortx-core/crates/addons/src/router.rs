//! Capability routing over an [`AddonCollection`]: which installed add-ons answer a request.
//!
//! Routing is the protocol capability check [`vortx_protocol::Manifest::supports`] applied across
//! the collection in priority order. `meta` / `stream` / `subtitles` aggregate across every matching
//! add-on (the engine fetches each); `catalog` rows are enumerated one rail per catalog.

use crate::collection::{AddonCollection, InstalledAddon};
use vortx_protocol::{resources, ManifestCatalog};

/// A catalog row paired with the add-on that serves it (one Discover/Board rail each).
#[derive(Debug, Clone, Copy)]
pub struct CatalogRef<'a> {
    pub addon: &'a InstalledAddon,
    pub catalog: &'a ManifestCatalog,
}

impl AddonCollection {
    /// The installed add-ons that can answer `resource` for `(type_, id)`, in install (priority)
    /// order. Use it for `meta` / `stream` / `subtitles` (fetch each and aggregate) and to resolve a
    /// specific `catalog` by id; use [`AddonCollection::catalogs`] to enumerate every catalog rail.
    pub fn resolve(&self, resource: &str, type_: &str, id: &str) -> Vec<&InstalledAddon> {
        self.iter()
            .filter(|addon| addon.manifest.supports(resource, type_, id))
            .collect()
    }

    /// Every catalog row across all add-ons that serve `catalog`, in install order. Catalogs that
    /// require an extra prop (search / genre) are still listed; the caller decides how to render
    /// them. Mirrors the web client's `catalogRefs`.
    pub fn catalogs(&self) -> Vec<CatalogRef<'_>> {
        let mut refs = Vec::new();
        for addon in self.iter() {
            let serves_catalog = addon
                .manifest
                .resources
                .iter()
                .any(|r| r.name() == resources::CATALOG);
            if !serves_catalog {
                continue;
            }
            for catalog in &addon.manifest.catalogs {
                refs.push(CatalogRef { addon, catalog });
            }
        }
        refs
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::collection::InstalledAddon;
    use vortx_protocol::parse_manifest;

    fn addon(transport: &str, manifest_json: &str) -> InstalledAddon {
        InstalledAddon::new(
            transport,
            parse_manifest(manifest_json).expect("manifest parses"),
        )
    }

    // Cinemeta: serves catalog (short form) + meta (narrowed to movie/series + tt). NO stream.
    const CINEMETA: &str = r#"{
        "id": "com.linvo.cinemeta", "version": "3.0.13", "name": "Cinemeta",
        "resources": ["catalog", { "name": "meta", "types": ["movie", "series"], "idPrefixes": ["tt"] }],
        "types": ["movie", "series"], "idPrefixes": ["tt"],
        "catalogs": [ { "type": "movie", "id": "top", "name": "Popular" },
                      { "type": "series", "id": "top", "name": "Popular" } ]
    }"#;

    // Torrentio: stream-only, IMDb (tt) ids.
    const TORRENTIO: &str = r#"{
        "id": "com.stremio.torrentio", "version": "1.0.0", "name": "Torrentio",
        "resources": ["stream"], "types": ["movie", "series"], "idPrefixes": ["tt"]
    }"#;

    // A kitsu-only stream add-on (narrowed by idPrefix in the resource object).
    const KITSU_STREAM: &str = r#"{
        "id": "community.anime", "version": "0.1.0", "name": "AnimeStreams",
        "resources": [ { "name": "stream", "types": ["movie", "series"], "idPrefixes": ["kitsu"] } ],
        "types": ["movie", "series"], "idPrefixes": ["kitsu"]
    }"#;

    fn three() -> AddonCollection {
        AddonCollection::from_vec(vec![
            addon("https://v3-cinemeta.strem.io/manifest.json", CINEMETA),
            addon("https://torrentio.strem.fun/manifest.json", TORRENTIO),
            addon("https://anime.example/manifest.json", KITSU_STREAM),
        ])
    }

    #[test]
    fn routes_tt_stream_to_only_the_tt_stream_addon() {
        let c = three();
        let hits = c.resolve("stream", "movie", "tt0111161");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].manifest.id, "com.stremio.torrentio");
    }

    #[test]
    fn routes_kitsu_stream_to_only_the_kitsu_addon() {
        let c = three();
        let hits = c.resolve("stream", "series", "kitsu:42:1:1");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].manifest.id, "community.anime");
    }

    #[test]
    fn catalog_only_addon_is_excluded_from_stream() {
        let c = three();
        // Cinemeta serves catalog + meta but NOT stream, so it must never answer a stream request.
        let hits = c.resolve("stream", "movie", "tt0111161");
        assert!(hits.iter().all(|a| a.manifest.id != "com.linvo.cinemeta"));
    }

    #[test]
    fn meta_routes_to_cinemeta_only() {
        let c = three();
        let hits = c.resolve("meta", "movie", "tt0111161");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].manifest.id, "com.linvo.cinemeta");
    }

    #[test]
    fn catalogs_enumerates_every_row_in_install_order() {
        let c = three();
        let rows = c.catalogs();
        // Only Cinemeta serves catalog, with two rows, in declared order.
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].catalog.id, "top");
        assert_eq!(rows[0].catalog.type_, "movie");
        assert_eq!(rows[1].catalog.type_, "series");
        assert!(rows
            .iter()
            .all(|r| r.addon.manifest.id == "com.linvo.cinemeta"));
    }
}
