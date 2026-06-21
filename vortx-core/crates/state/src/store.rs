//! The top-level engine state. `VortxStore` replaces stremio-core's single `Ctx` + `LibraryBucket`: every
//! profile is first-class and owns its own [`ProfileLibrary`]. This is what the engine's `get_state_json`
//! returns. Switching profiles is an instant re-point, not a `LoginWithToken` account swap.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ids::ProfileId;
use crate::library::ProfileLibrary;
use crate::profile::Profile;
use crate::roster::ProfileRoster;
use crate::StateError;

/// The per-profile engine state: the profile roster, the active profile, and one library bucket per
/// profile.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct VortxStore {
    #[serde(default)]
    pub roster: ProfileRoster,
    #[serde(rename = "activeProfileId")]
    pub active_profile_id: ProfileId,
    #[serde(default)]
    pub libraries: BTreeMap<ProfileId, ProfileLibrary>,
}

impl VortxStore {
    /// A fresh store seeded with the owner profile (active) and its empty library.
    pub fn new(owner: Profile) -> Self {
        let active_profile_id = owner.id.clone();
        let mut roster = ProfileRoster::new();
        roster.upsert(owner);
        let mut libraries = BTreeMap::new();
        libraries.insert(active_profile_id.clone(), ProfileLibrary::default());
        Self {
            roster,
            active_profile_id,
            libraries,
        }
    }

    /// Switch the active profile. Instant: re-point `active` to a LIVE, existing profile and ensure it has
    /// a library bucket. No re-auth and no account library re-pull, the break from stremio-core where the
    /// only way to change persona is a full `LoginWithToken` account swap.
    pub fn switch_profile(&mut self, id: &ProfileId) -> Result<(), StateError> {
        match self.roster.get(id) {
            None => Err(StateError::ProfileNotFound),
            Some(profile) if profile.deleted => Err(StateError::ProfileDeleted),
            Some(_) => {
                self.libraries.entry(id.clone()).or_default();
                self.active_profile_id = id.clone();
                Ok(())
            }
        }
    }

    /// The active profile (if it still exists in the roster).
    pub fn active_profile(&self) -> Option<&Profile> {
        self.roster.get(&self.active_profile_id)
    }

    /// The active profile's library (if a bucket exists).
    pub fn active_library(&self) -> Option<&ProfileLibrary> {
        self.libraries.get(&self.active_profile_id)
    }

    /// The active profile's library, creating an empty bucket if needed.
    pub fn active_library_mut(&mut self) -> &mut ProfileLibrary {
        self.libraries
            .entry(self.active_profile_id.clone())
            .or_default()
    }

    /// A specific profile's library, if a bucket exists.
    pub fn library(&self, id: &ProfileId) -> Option<&ProfileLibrary> {
        self.libraries.get(id)
    }

    /// A specific profile's library, creating an empty bucket if needed (for applying a synced watch
    /// document to a profile that has no local bucket yet).
    pub fn library_mut(&mut self, id: &ProfileId) -> &mut ProfileLibrary {
        self.libraries.entry(id.clone()).or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner() -> Profile {
        let mut p = Profile::new(ProfileId::new("owner"), "Owner");
        p.owner = true;
        p
    }

    #[test]
    fn new_store_seeds_owner_active_with_empty_library() {
        let store = VortxStore::new(owner());
        assert_eq!(store.active_profile_id, ProfileId::new("owner"));
        assert!(store.active_profile().unwrap().owner);
        assert!(store.active_library().unwrap().items.is_empty());
    }

    #[test]
    fn switch_to_a_second_profile_is_instant_and_creates_its_bucket() {
        let mut store = VortxStore::new(owner());
        store
            .roster
            .upsert(Profile::new(ProfileId::new("kid"), "Kid"));
        assert!(store.library(&ProfileId::new("kid")).is_none());

        store.switch_profile(&ProfileId::new("kid")).unwrap();
        assert_eq!(store.active_profile_id, ProfileId::new("kid"));
        // A bucket was created for the target on switch.
        assert!(store.library(&ProfileId::new("kid")).is_some());
        // The owner's library bucket is untouched (separate per profile).
        assert!(store.library(&ProfileId::new("owner")).is_some());
    }

    #[test]
    fn switch_to_unknown_profile_errors() {
        let mut store = VortxStore::new(owner());
        assert_eq!(
            store.switch_profile(&ProfileId::new("ghost")),
            Err(StateError::ProfileNotFound)
        );
    }

    #[test]
    fn switch_to_deleted_profile_errors() {
        let mut store = VortxStore::new(owner());
        store
            .roster
            .upsert(Profile::new(ProfileId::new("kid"), "Kid"));
        store.roster.delete(&ProfileId::new("kid"), 100).unwrap();
        assert_eq!(
            store.switch_profile(&ProfileId::new("kid")),
            Err(StateError::ProfileDeleted)
        );
    }

    #[test]
    fn store_serde_round_trip() {
        let mut store = VortxStore::new(owner());
        store
            .roster
            .upsert(Profile::new(ProfileId::new("kid"), "Kid"));
        let json = serde_json::to_string(&store).unwrap();
        let back: VortxStore = serde_json::from_str(&json).unwrap();
        assert_eq!(store, back);
    }
}
