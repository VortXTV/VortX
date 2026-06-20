//! Canonical manifest serialization: the deterministic byte form an ed25519 signature covers, so
//! reformatting the JSON can never invalidate a signature. Object keys are sorted, output is compact (no
//! insignificant whitespace), and scalars serialize through `serde_json` (string escaping + number
//! formatting). The TS SDK reimplements this byte-for-byte (a later chunk), gated by shared vectors.

use serde_json::Value;

use crate::manifest::VortxAddonManifest;

/// Produce the canonical bytes for a manifest.
pub fn canonicalize(manifest: &VortxAddonManifest) -> Result<Vec<u8>, serde_json::Error> {
    let value = serde_json::to_value(manifest)?;
    let mut out = Vec::new();
    write_canonical(&value, &mut out);
    Ok(out)
}

fn write_canonical(value: &Value, out: &mut Vec<u8>) {
    match value {
        Value::Object(map) => {
            out.push(b'{');
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_unstable();
            for (i, key) in keys.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_scalar(&Value::String((*key).clone()), out);
                out.push(b':');
                write_canonical(&map[*key], out);
            }
            out.push(b'}');
        }
        Value::Array(arr) => {
            out.push(b'[');
            for (i, item) in arr.iter().enumerate() {
                if i > 0 {
                    out.push(b',');
                }
                write_canonical(item, out);
            }
            out.push(b']');
        }
        scalar => write_scalar(scalar, out),
    }
}

fn write_scalar(value: &Value, out: &mut Vec<u8>) {
    // serde_json serializes scalars deterministically; a scalar value never fails to serialize.
    let bytes = serde_json::to_vec(value).expect("scalar serialization is infallible");
    out.extend_from_slice(&bytes);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::VortxTransport;

    fn manifest() -> VortxAddonManifest {
        VortxAddonManifest::native(
            "tv.vortx.theme.midnight",
            "1.0.0",
            "Midnight",
            VortxTransport::Federated {
                endpoint: "local".into(),
            },
        )
    }

    #[test]
    fn canonical_keys_are_sorted() {
        let bytes = canonicalize(&manifest()).unwrap();
        let s = String::from_utf8(bytes).unwrap();
        // Top-level keys appear in sorted order; "id" precedes "name" precedes "schema".
        let id = s.find("\"id\"").unwrap();
        let name = s.find("\"name\"").unwrap();
        let schema = s.find("\"schema\"").unwrap();
        assert!(id < name && name < schema, "keys must be sorted: {s}");
    }

    #[test]
    fn canonical_is_idempotent_through_reparse() {
        let once = canonicalize(&manifest()).unwrap();
        let reparsed: VortxAddonManifest = serde_json::from_slice(&once).unwrap();
        let twice = canonicalize(&reparsed).unwrap();
        assert_eq!(once, twice);
    }

    #[test]
    fn canonical_has_no_insignificant_whitespace() {
        let bytes = canonicalize(&manifest()).unwrap();
        let s = String::from_utf8(bytes).unwrap();
        assert!(!s.contains("\n"));
        assert!(!s.contains(": "));
        assert!(!s.contains(", "));
    }
}
