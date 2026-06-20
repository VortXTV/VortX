//! Stable profile identifiers. A `ProfileId` is a stable UUID-style string, not an account uid and not a
//! reusable integer slot, so a deleted-then-recreated profile never aliases the old one's data.

use serde::{Deserialize, Serialize};

/// A stable, opaque profile identifier (the sync/merge key). Ordered so it can key a `BTreeMap` for an
/// order-independent roster.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub struct ProfileId(pub String);

impl ProfileId {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ProfileId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
