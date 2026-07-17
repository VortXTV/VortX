//! A redaction-only secret (Xtream username/password, portal MAC, debrid token used to build a live URL).
//!
//! The privacy contract, stronger than any competitor's "store the creds in the channel object":
//! - `Debug` and `Display` NEVER print the value, so a secret can never slip into a log line, a panic
//!   message, or a `dbg!`.
//! - `Serialize` emits ONLY the one-way redaction key (an FNV-1a hash), never the value, so a secret can
//!   never leak into sync state or a federated hive fact. There is deliberately NO `Deserialize`: a secret
//!   is supplied by the host at the I/O boundary, never reconstructed from its hash (it cannot be).
//! - `key()` is a stable, non-reversible handle: cache keys and channel ids derive from the HASH of the
//!   secret, so credentials never appear in `channel_id`, logs, or hive payloads, yet the same credentials
//!   still produce the same cache/identity key across devices.
//! - `reveal()` is the single, greppable escape hatch, called only when building the upstream request.

use core::fmt;

use serde::{Serialize, Serializer};

use crate::hash::fnv1a64;

/// A credential whose value is never printed or serialized. See the module docs for the full contract.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    /// Wrap a raw credential.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// The raw value. ONLY call at the host I/O boundary when building the upstream request; never log,
    /// serialize, or embed the result in an identity. This is the one intentional, greppable escape hatch.
    pub fn reveal(&self) -> &str {
        &self.0
    }

    /// A stable, one-way redaction key (FNV-1a hex). Safe to put in cache keys, channel ids, and logs: it is
    /// the same for the same value on every device, and the value cannot be recovered from it.
    pub fn key(&self) -> String {
        format!("{:016x}", fnv1a64(self.0.as_bytes()))
    }

    /// Whether the wrapped credential is empty (e.g. an anonymous/keyless provider).
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Show the redaction key, never the value, so debug output is still correlatable but leak-free.
        write!(f, "Secret(redacted:{})", self.key())
    }
}

impl fmt::Display for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("<redacted>")
    }
}

impl Serialize for Secret {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        // Serialize the one-way key, NEVER the value: a secret in a synced/federated payload is just a hash.
        serializer.serialize_str(&self.key())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_and_display_never_reveal_the_value() {
        let s = Secret::new("hunter2");
        assert!(!format!("{s:?}").contains("hunter2"));
        assert!(!format!("{s}").contains("hunter2"));
        assert_eq!(format!("{s}"), "<redacted>");
    }

    #[test]
    fn serialization_emits_only_the_one_way_key() {
        let s = Secret::new("hunter2");
        let json = serde_json::to_string(&s).unwrap();
        assert!(!json.contains("hunter2"));
        assert_eq!(json, format!("\"{}\"", s.key()));
    }

    #[test]
    fn key_is_stable_for_equal_values_and_distinct_otherwise() {
        assert_eq!(Secret::new("abc").key(), Secret::new("abc").key());
        assert_ne!(Secret::new("abc").key(), Secret::new("abd").key());
    }

    #[test]
    fn reveal_returns_the_value_at_the_boundary() {
        assert_eq!(Secret::new("user1").reveal(), "user1");
    }
}
