//! The catalog-layer bridge for parental controls. The fan-out aggregator works on bare id strings, so
//! rating-aware enforcement belongs here, where catalog rows are [`MetaPreview`]s that carry a
//! `certification`. These two pure helpers are what the engine calls to (1) build the meta->rating map a
//! [`crate::MaturityGate`] / [`crate::build_home_feed`] consume, and (2) filter raw catalog rows for a
//! profile before they are ever shown.

use std::collections::HashMap;

use vortx_protocol::MetaPreview;
use vortx_state::{maturity_allows, parse_certification, MaturityRating, ParentalFlags};

/// Reconcile a catalog's certifications into the `meta id -> rating` map (`None` = unrated/unknown) that
/// the maturity gate and the Home feed consume. One reconciliation pass over the catalog, reused by every
/// lane.
pub fn catalog_ratings(metas: &[MetaPreview]) -> HashMap<String, Option<MaturityRating>> {
    metas
        .iter()
        .map(|m| {
            (
                m.id.clone(),
                m.certification.as_deref().and_then(parse_certification),
            )
        })
        .collect()
}

/// Filter a catalog to the rows a profile may see. Parental enforcement at the catalog layer: a kids
/// profile never even receives an over-ceiling or unrated row (fail-closed), so nothing downstream has to
/// re-check it.
pub fn visible_catalog<'a>(metas: &'a [MetaPreview], flags: &ParentalFlags) -> Vec<&'a MetaPreview> {
    metas
        .iter()
        .filter(|m| {
            maturity_allows(
                flags,
                m.certification.as_deref().and_then(parse_certification),
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(id: &str, cert: Option<&str>) -> MetaPreview {
        MetaPreview {
            id: id.into(),
            type_: "movie".into(),
            name: id.into(),
            poster: None,
            poster_shape: None,
            background: None,
            logo: None,
            description: None,
            release_info: None,
            imdb_rating: None,
            certification: cert.map(str::to_string),
            genres: None,
        }
    }

    #[test]
    fn ratings_reconcile_each_scheme() {
        let metas = [meta("a", Some("PG-13")), meta("b", Some("TV-MA")), meta("c", None)];
        let r = catalog_ratings(&metas);
        assert_eq!(r["a"], Some(MaturityRating(13)));
        assert_eq!(r["b"], Some(MaturityRating(17)));
        assert_eq!(r["c"], None); // unrated
    }

    #[test]
    fn kids_catalog_drops_over_ceiling_and_unrated() {
        let flags = ParentalFlags {
            kids: true,
            ..Default::default()
        };
        let metas = [meta("g", Some("G")), meta("r", Some("R")), meta("u", None)];
        let visible: Vec<&str> = visible_catalog(&metas, &flags)
            .iter()
            .map(|m| m.id.as_str())
            .collect();
        assert_eq!(visible, vec!["g"]); // R over ceiling, None fail-closed
    }

    #[test]
    fn unrestricted_catalog_keeps_everything() {
        let flags = ParentalFlags::default();
        let metas = [meta("g", Some("G")), meta("r", Some("R")), meta("u", None)];
        assert_eq!(visible_catalog(&metas, &flags).len(), 3);
    }
}
