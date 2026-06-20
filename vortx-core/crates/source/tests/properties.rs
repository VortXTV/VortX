//! Property-based check that a ResourceRequest maps to the byte-exact Stremio transport path deterministically
//! and never panics, for arbitrary inputs. This keeps the native request type and the Stremio URL grammar
//! in lockstep across platforms.

use proptest::prelude::*;
use vortx_protocol::ResourcePath;
use vortx_source::{ResourceKind, ResourceRequest};

fn kind_strategy() -> impl Strategy<Value = ResourceKind> {
    prop_oneof![
        Just(ResourceKind::Catalog),
        Just(ResourceKind::Meta),
        Just(ResourceKind::Stream),
        Just(ResourceKind::Subtitles),
        Just(ResourceKind::Ratings),
        Just(ResourceKind::MusicStream),
    ]
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn request_to_path_is_deterministic_and_never_panics(
        kind in kind_strategy(),
        type_ in "[a-z]{3,8}",
        id in "[a-zA-Z0-9:]{1,20}",
        extra in prop::collection::vec(("[a-z]{1,5}", "[a-zA-Z0-9 &]{1,8}"), 0..4usize),
    ) {
        let mut req = ResourceRequest::new(kind, type_, id);
        for (key, value) in &extra {
            req = req.with_extra(key.clone(), value.clone());
        }

        let path_a: ResourcePath = (&req).into();
        let path_b: ResourcePath = (&req).into();

        // Building the URL never panics, and is stable for the same request.
        let url_a = path_a.to_url("https://addon.example/manifest.json");
        let url_b = path_b.to_url("https://addon.example/manifest.json");
        prop_assert_eq!(url_a, url_b);
    }
}
