//! Per-profile debrid credentials. Each profile can carry its own opaque `store:apikey` token, so the
//! rest of the engine stays store-agnostic. THIS format is the credential wire contract, pinned by the
//! conformance vectors.

use vortx_hive::DebridService;

/// Parse a `store:apikey` token into `(service, api_key)`. Only the FIRST colon splits, so the api key may
/// itself contain colons. Returns `None` for an unknown store or an empty key.
pub fn parse_credential(token: &str) -> Option<(DebridService, String)> {
    let (store, key) = token.split_once(':')?;
    if key.is_empty() {
        return None;
    }
    let service: DebridService =
        serde_json::from_value(serde_json::Value::String(store.to_string())).ok()?;
    Some((service, key.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_basic_token() {
        assert_eq!(
            parse_credential("realdebrid:ABC123"),
            Some((DebridService::RealDebrid, "ABC123".to_string()))
        );
    }

    #[test]
    fn api_key_may_contain_colons() {
        // Only the first colon splits; the rest is the key verbatim.
        assert_eq!(
            parse_credential("torbox:a:b:c"),
            Some((DebridService::TorBox, "a:b:c".to_string()))
        );
    }

    #[test]
    fn unknown_store_is_rejected() {
        assert!(parse_credential("notastore:key").is_none());
    }

    #[test]
    fn missing_colon_is_rejected() {
        assert!(parse_credential("realdebrid").is_none());
    }

    #[test]
    fn empty_key_is_rejected() {
        assert!(parse_credential("realdebrid:").is_none());
    }
}
