//! Property-based proof that the Nuvio adapter is lossless on the load-bearing fields: every input stream
//! produces exactly one output stream, and its url and label survive the mapping.

use proptest::prelude::*;
use vortx_adapters::{scraper_streams_to_protocol, NuvioStream};

fn nuvio(url: &str, name: Option<String>, quality: Option<String>) -> NuvioStream {
    NuvioStream {
        name,
        title: None,
        url: url.to_string(),
        quality,
        size: None,
        headers: None,
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(128))]

    #[test]
    fn mapping_preserves_count_url_and_label(
        rows in prop::collection::vec(
            ("[a-z]{3,10}", prop::option::of("[A-Za-z0-9 ]{1,12}"), prop::option::of("[0-9]{3,4}p")),
            0..20usize,
        )
    ) {
        let raw: Vec<NuvioStream> = rows
            .iter()
            .map(|(slug, name, quality)| nuvio(&format!("https://x/{slug}"), name.clone(), quality.clone()))
            .collect();

        let out = scraper_streams_to_protocol(&raw);

        prop_assert_eq!(out.len(), raw.len());
        for (mapped, source) in out.iter().zip(raw.iter()) {
            prop_assert_eq!(mapped.url.as_deref(), Some(source.url.as_str()));
            // Label is name when present, else quality.
            let expected = source.name.clone().or_else(|| source.quality.clone());
            prop_assert_eq!(mapped.name.clone(), expected);
        }
    }
}
