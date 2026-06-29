//! Stable, dependency-free FNV-1a 64-bit hash. Used for the credential redaction key ([`crate::Secret`]) and
//! the fallback channel id (when a feed has no tvg-id). `wrapping_mul` makes it byte-identical on every
//! platform (no overflow panic, no float, no platform-dependent `std` hasher), so an id or a secret key
//! computed on Apple, Android, and wasm always agree. This is an identity primitive, never a security MAC.

/// FNV-1a 64-bit over `bytes`. Deterministic and cross-platform.
pub(crate) fn fnv1a64(bytes: &[u8]) -> u64 {
    const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
    const PRIME: u64 = 0x0000_0100_0000_01b3;
    let mut hash = OFFSET;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_known_fnv1a_test_vectors() {
        // The canonical FNV-1a 64 reference values, so a port in another language can pin against them.
        assert_eq!(fnv1a64(b""), 0xcbf2_9ce4_8422_2325);
        assert_eq!(fnv1a64(b"a"), 0xaf63_dc4c_8601_ec8c);
        assert_eq!(fnv1a64(b"foobar"), 0x8594_4171_f739_67e8);
    }

    #[test]
    fn is_deterministic_and_order_sensitive() {
        assert_eq!(fnv1a64(b"cnn"), fnv1a64(b"cnn"));
        assert_ne!(fnv1a64(b"ab"), fnv1a64(b"ba"));
    }
}
