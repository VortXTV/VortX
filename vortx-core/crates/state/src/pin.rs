//! Parental-PIN hashing. A PIN is a GATE, not a cryptographic boundary, so a salted SHA-256 is enough.
//! The salt is the non-secret synced profile id, so the hash is reproducible on every platform. The
//! preimage string is the cross-language contract (the SHA-256 itself is standard), pinned by the
//! conformance vectors so the Swift app, web client, and dashboard verify a PIN identically.

use sha2::{Digest, Sha256};

/// The exact string hashed for a profile's PIN: `"<profile_id>:<pin>"`. THIS is the cross-platform
/// contract (see conformance/pin_preimage_vectors.json); any implementation that builds this string and
/// SHA-256s it produces the same hash.
pub fn pin_preimage(profile_id: &str, pin: &str) -> String {
    format!("{profile_id}:{pin}")
}

/// The lowercase-hex SHA-256 of the [`pin_preimage`].
pub fn hash_pin(profile_id: &str, pin: &str) -> String {
    let digest = Sha256::digest(pin_preimage(profile_id, pin).as_bytes());
    let mut out = String::with_capacity(64);
    for byte in digest {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// Verify a PIN against a stored hash. Case-insensitive hex compare; also tolerates a stored LEGACY
/// plaintext PIN (older builds stored the PIN directly) so existing profiles keep working.
pub fn verify_pin(profile_id: &str, pin: &str, stored: &str) -> bool {
    hash_pin(profile_id, pin).eq_ignore_ascii_case(stored) || pin == stored
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hash_is_64_hex_chars() {
        let h = hash_pin("p1", "1234");
        assert_eq!(h.len(), 64);
        assert!(h.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn verify_round_trip() {
        let h = hash_pin("p1", "1234");
        assert!(verify_pin("p1", "1234", &h));
        assert!(!verify_pin("p1", "0000", &h));
    }

    #[test]
    fn salt_matters_same_pin_different_profile() {
        // The same PIN under two profiles must hash differently (the profile id is the salt).
        assert_ne!(hash_pin("p1", "1234"), hash_pin("p2", "1234"));
    }

    #[test]
    fn tolerates_legacy_plaintext_pin() {
        assert!(verify_pin("p1", "1234", "1234"));
        assert!(!verify_pin("p1", "9999", "1234"));
    }

    #[test]
    fn preimage_is_the_documented_shape() {
        assert_eq!(pin_preimage("abc", "0420"), "abc:0420");
    }
}
