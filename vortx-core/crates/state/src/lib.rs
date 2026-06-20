//! # vortx-state
//!
//! The per-profile state foundation. In stremio-core a "profile" IS the Stremio account: the `Ctx`
//! holds exactly one `Profile` + one `LibraryBucket` keyed to one account uid, so VortX's multi-profile
//! is faked today as a Swift overlay (`ProfileStore`) that must constantly guard against writing the
//! account library. This crate makes profile a FIRST-CLASS engine entity instead:
//!
//! - [`Profile`] : a viewer persona (not an account). The account is just one attribute
//!   ([`AccountBinding`]): `Own(uid)`, `Shared(other_profile)` (the family-on-one-account case
//!   stremio-core cannot express), or `LocalOnly`.
//! - [`ProfileRoster`] : the convergent set of profiles. Merging is UNION-by-id (a profile present on
//!   only one device is never dropped, the guard born from a real data-loss incident) with last-writer
//!   wins per id by a strict total order, and deletes are TOMBSTONES a later edit can revive. Proven a
//!   CRDT by the `roster_properties` property tests.
//! - [`hash_pin`] : parental-PIN hashing over a fixed cross-platform preimage (see the conformance
//!   vectors), so the Swift app, the web client, and the dashboard all verify a PIN identically.
//!
//! Anti-regression invariants carried forward (and made structural in later chunks): per-profile data is
//! never serialized into a Stremio `libraryItem`; the account token stays in the Keychain only; the
//! roster never silently drops a profile.

mod ids;
mod library;
mod pin;
mod profile;
mod roster;
mod store;

pub use ids::ProfileId;
pub use library::{
    CwItem, HistoryEntry, LibraryItem, ProfileLibrary, ResumePoint, StremioLibraryItem,
    WatchedBitfield,
};
pub use pin::{hash_pin, pin_preimage, verify_pin};
pub use profile::{AccountBinding, AddonBinding, ParentalFlags, Profile, ProfileSettings};
pub use roster::ProfileRoster;
pub use store::VortxStore;

/// Errors from profile-state operations.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum StateError {
    #[error("profile not found")]
    ProfileNotFound,
    #[error("profile is deleted")]
    ProfileDeleted,
    #[error("cannot delete the owner profile")]
    CannotDeleteOwner,
    #[error("cannot delete the last remaining profile")]
    CannotDeleteLastProfile,
}
