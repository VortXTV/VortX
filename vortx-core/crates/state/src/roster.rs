//! The profile roster: the convergent set of profiles, keyed by stable id.
//!
//! Merging is UNION-by-id (a profile present on only one device is never dropped) with last-writer-wins
//! per id by a STRICT TOTAL ORDER on `(rev, serialized-content)`. Because the order is total, the merge
//! is commutative, associative, and idempotent, so two devices converge to the same roster regardless of
//! sync order (proven in `roster_properties`). Deletes are tombstones a newer edit can revive, which,
//! with the union rule, is the structural form of the "never silently drop a profile" guard.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ids::ProfileId;
use crate::profile::Profile;
use crate::StateError;

/// A convergent, order-independent set of profiles.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ProfileRoster {
    profiles: BTreeMap<ProfileId, Profile>,
}

/// The total-order LWW key for a profile: newer `rev` wins; ties break by serialized content so even two
/// concurrent same-rev edits resolve deterministically.
fn merge_key(p: &Profile) -> (u64, String) {
    (p.rev, serde_json::to_string(p).unwrap_or_default())
}

impl ProfileRoster {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_profiles(profiles: impl IntoIterator<Item = Profile>) -> Self {
        let mut roster = Self::new();
        for p in profiles {
            roster.upsert(p);
        }
        roster
    }

    /// Insert or update a profile by id using the LWW total order (a strictly-greater version wins; an
    /// equal version is a no-op, which is what makes the merge idempotent).
    pub fn upsert(&mut self, profile: Profile) {
        match self.profiles.get(&profile.id) {
            Some(existing) if merge_key(existing) >= merge_key(&profile) => {}
            _ => {
                self.profiles.insert(profile.id.clone(), profile);
            }
        }
    }

    /// Merge another roster into this one (union-by-id + LWW). Commutative, associative, idempotent.
    pub fn merge(&mut self, other: &ProfileRoster) {
        for p in other.profiles.values() {
            self.upsert(p.clone());
        }
    }

    pub fn get(&self, id: &ProfileId) -> Option<&Profile> {
        self.profiles.get(id)
    }

    /// All profiles including tombstones, in id order.
    pub fn iter(&self) -> impl Iterator<Item = &Profile> {
        self.profiles.values()
    }

    /// Live (non-tombstoned) profiles in id order.
    pub fn live(&self) -> impl Iterator<Item = &Profile> {
        self.profiles.values().filter(|p| !p.deleted)
    }

    pub fn live_count(&self) -> usize {
        self.profiles.values().filter(|p| !p.deleted).count()
    }

    pub fn len(&self) -> usize {
        self.profiles.len()
    }

    pub fn is_empty(&self) -> bool {
        self.profiles.is_empty()
    }

    /// Tombstone-delete a profile. Guards: never the owner, never the last LIVE profile; idempotent if
    /// already deleted. Bumps `rev` so the tombstone wins LWW when it syncs.
    pub fn delete(&mut self, id: &ProfileId, now: u64) -> Result<(), StateError> {
        let live = self.live_count();
        let profile = self
            .profiles
            .get_mut(id)
            .ok_or(StateError::ProfileNotFound)?;
        if profile.owner {
            return Err(StateError::CannotDeleteOwner);
        }
        if profile.deleted {
            return Ok(());
        }
        if live <= 1 {
            return Err(StateError::CannotDeleteLastProfile);
        }
        profile.deleted = true;
        profile.rev = profile.rev.saturating_add(1);
        profile.updated_at = now;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile(id: &str, rev: u64) -> Profile {
        let mut p = Profile::new(ProfileId::new(id), id);
        p.rev = rev;
        p
    }

    #[test]
    fn merge_is_union_by_id() {
        let mut a = ProfileRoster::from_profiles([profile("p1", 0)]);
        let b = ProfileRoster::from_profiles([profile("p2", 0)]);
        a.merge(&b);
        // A profile present on only one side is kept, never dropped.
        assert_eq!(a.len(), 2);
        assert!(a.get(&ProfileId::new("p1")).is_some());
        assert!(a.get(&ProfileId::new("p2")).is_some());
    }

    #[test]
    fn lww_higher_rev_wins() {
        let mut a = ProfileRoster::from_profiles([profile("p1", 1)]);
        a.upsert(profile("p1", 3)); // newer
        a.upsert(profile("p1", 2)); // older, ignored
        assert_eq!(a.get(&ProfileId::new("p1")).unwrap().rev, 3);
    }

    #[test]
    fn upsert_is_idempotent() {
        let mut a = ProfileRoster::new();
        a.upsert(profile("p1", 5));
        let before = a.clone();
        a.upsert(profile("p1", 5));
        assert_eq!(a, before);
    }

    #[test]
    fn delete_tombstones_a_profile() {
        let mut a = ProfileRoster::from_profiles([profile("p1", 0), profile("p2", 0)]);
        assert!(a.delete(&ProfileId::new("p2"), 100).is_ok());
        assert!(a.get(&ProfileId::new("p2")).unwrap().deleted);
        assert_eq!(a.live_count(), 1);
        assert_eq!(a.len(), 2); // tombstone retained
    }

    #[test]
    fn cannot_delete_owner() {
        let mut owner = profile("p1", 0);
        owner.owner = true;
        let mut a = ProfileRoster::from_profiles([owner, profile("p2", 0)]);
        assert_eq!(
            a.delete(&ProfileId::new("p1"), 100),
            Err(StateError::CannotDeleteOwner)
        );
    }

    #[test]
    fn cannot_delete_last_live_profile() {
        let mut a = ProfileRoster::from_profiles([profile("p1", 0)]);
        assert_eq!(
            a.delete(&ProfileId::new("p1"), 100),
            Err(StateError::CannotDeleteLastProfile)
        );
    }

    #[test]
    fn delete_is_idempotent() {
        let mut a = ProfileRoster::from_profiles([profile("p1", 0), profile("p2", 0)]);
        assert!(a.delete(&ProfileId::new("p2"), 100).is_ok());
        assert!(a.delete(&ProfileId::new("p2"), 200).is_ok()); // already deleted -> ok, no change
        assert_eq!(a.live_count(), 1);
    }
}
