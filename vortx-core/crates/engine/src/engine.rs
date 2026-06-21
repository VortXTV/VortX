//! The runtime and the dispatch core. `init_runtime` builds an [`Engine`] over the first-class
//! multi-profile [`VortxStore`]; `dispatch_json` applies one JSON [`Action`] and returns a JSON
//! [`DispatchResult`]; `get_state_json` serializes the state. These three are the exact shape the
//! platform FFI (extern C / JNI / wasm) wraps in a later phase; here they are pure Rust and fully
//! testable. Resource resolution (routing requests into the source / debrid / ranking crates) joins
//! `dispatch` in a later phase.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use vortx_state::{Profile, ProfileId, ProfileLibrary, VortxStore};

use crate::action::{Action, DispatchResult, EngineEvent};
use crate::env::Env;

/// The engine runtime: the per-profile state, plus a DIRTY set tracking what changed since the last delta
/// snapshot so the host can persist O(changed) records instead of re-serializing the whole store.
pub struct Engine {
    store: VortxStore,
    dirty: Dirty,
}

/// Which records changed since the last [`take_state_delta`]. Runtime-only (never persisted): on a cold
/// load the host takes a full [`get_state_json`] snapshot, then persists deltas after each dispatch.
#[derive(Debug, Default)]
struct Dirty {
    profiles: BTreeSet<ProfileId>,
    libraries: BTreeSet<ProfileId>,
    active_changed: bool,
}

impl Dirty {
    fn is_empty(&self) -> bool {
        self.profiles.is_empty() && self.libraries.is_empty() && !self.active_changed
    }

    fn clear(&mut self) {
        self.profiles.clear();
        self.libraries.clear();
        self.active_changed = false;
    }
}

/// The records that changed since the last snapshot: only the changed profiles + library buckets (and the
/// active id, if it moved). The host applies this as an upsert, so persistence cost scales with what
/// changed, not with total library size.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StateDelta {
    #[serde(rename = "activeProfileId", default, skip_serializing_if = "Option::is_none")]
    pub active_profile_id: Option<ProfileId>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub profiles: Vec<Profile>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub libraries: BTreeMap<ProfileId, ProfileLibrary>,
}

impl Engine {
    /// The current engine state (read-only).
    pub fn store(&self) -> &VortxStore {
        &self.store
    }

    /// Whether anything has changed since the last delta snapshot.
    pub fn has_pending_changes(&self) -> bool {
        !self.dirty.is_empty()
    }
}

/// Build a runtime seeded with the owner profile (active) and its empty library. The dirty set starts
/// empty: the host persists the initial state via a full `get_state_json`, then deltas thereafter.
pub fn init_runtime(owner_id: &str, owner_name: &str) -> Engine {
    let mut owner = Profile::new(ProfileId::new(owner_id), owner_name);
    owner.owner = true;
    Engine {
        store: VortxStore::new(owner),
        dirty: Dirty::default(),
    }
}

/// Apply one typed action to the engine. Pure over `(state, action, env)`; never panics.
pub fn dispatch(engine: &mut Engine, action: Action, env: &dyn Env) -> DispatchResult {
    match action {
        Action::SwitchProfile { id } => {
            let pid = ProfileId::new(id.clone());
            match engine.store.switch_profile(&pid) {
                Ok(()) => {
                    engine.dirty.active_changed = true;
                    engine.dirty.libraries.insert(pid); // switch ensures a library bucket
                    DispatchResult::ok(vec![EngineEvent::ProfileSwitched { id }])
                }
                Err(e) => DispatchResult::err(e.to_string()),
            }
        }
        Action::AddProfile { id, name } => {
            let pid = ProfileId::new(id.clone());
            engine.store.roster.upsert(Profile::new(pid.clone(), name));
            engine.dirty.profiles.insert(pid);
            DispatchResult::ok(vec![EngineEvent::ProfileAdded { id }])
        }
        Action::DeleteProfile { id } => {
            let pid = ProfileId::new(id.clone());
            match engine.store.roster.delete(&pid, env.now()) {
                Ok(()) => {
                    engine.dirty.profiles.insert(pid); // the tombstone is a changed record
                    DispatchResult::ok(vec![EngineEvent::ProfileDeleted { id }])
                }
                Err(e) => DispatchResult::err(e.to_string()),
            }
        }
        Action::SetParental {
            id,
            kids,
            maturity_ceiling,
        } => {
            let pid = ProfileId::new(id.clone());
            match engine.store.roster.get(&pid) {
                Some(p) => {
                    let mut updated = p.clone();
                    updated.parental.kids = kids;
                    updated.parental.maturity_ceiling = maturity_ceiling;
                    // Bump the LWW clock so this edit wins on a multi-device merge.
                    updated.rev = updated.rev.saturating_add(1);
                    updated.updated_at = env.now();
                    engine.store.roster.upsert(updated);
                    engine.dirty.profiles.insert(pid);
                    DispatchResult::ok(vec![EngineEvent::ParentalSet { id }])
                }
                None => DispatchResult::err("profile not found"),
            }
        }
        Action::SetRankingPrefs { id, prefs } => {
            let pid = ProfileId::new(id.clone());
            match engine.store.roster.get(&pid) {
                Some(p) => {
                    let mut updated = p.clone();
                    updated.settings.ranking = prefs;
                    updated.rev = updated.rev.saturating_add(1);
                    updated.updated_at = env.now();
                    engine.store.roster.upsert(updated);
                    engine.dirty.profiles.insert(pid);
                    DispatchResult::ok(vec![EngineEvent::RankingPrefsSet { id }])
                }
                None => DispatchResult::err("profile not found"),
            }
        }
        Action::ReportProgress {
            meta_id,
            video_id,
            name,
            position_ms,
            duration_ms,
        } => {
            engine.store.active_library_mut().report_progress(
                &meta_id,
                video_id.as_deref(),
                position_ms,
                duration_ms,
                &name,
                env.now(),
            );
            let pid = engine.store.active_profile_id.clone();
            engine.dirty.libraries.insert(pid);
            DispatchResult::ok(vec![EngineEvent::ProgressReported { id: meta_id }])
        }
        Action::MarkWatched { meta_id, video_id } => {
            engine
                .store
                .active_library_mut()
                .mark_watched(&meta_id, video_id.as_deref(), env.now());
            let pid = engine.store.active_profile_id.clone();
            engine.dirty.libraries.insert(pid);
            DispatchResult::ok(vec![EngineEvent::Watched { id: meta_id }])
        }
        Action::RemoveFromContinueWatching { meta_id } => {
            engine
                .store
                .active_library_mut()
                .remove_from_continue_watching(&meta_id);
            let pid = engine.store.active_profile_id.clone();
            engine.dirty.libraries.insert(pid);
            DispatchResult::ok(vec![EngineEvent::RemovedFromCw { id: meta_id }])
        }
        Action::GetState => DispatchResult::ok(vec![]),
    }
}

/// The FFI entry point: a JSON action string in, a JSON result string out. A malformed action yields a
/// well-formed `{ ok: false, error }` result rather than an error, so the host always gets parseable JSON.
pub fn dispatch_json(engine: &mut Engine, action_json: &str, env: &dyn Env) -> String {
    let result = match serde_json::from_str::<Action>(action_json) {
        Ok(action) => dispatch(engine, action, env),
        Err(e) => DispatchResult::err(format!("bad action: {e}")),
    };
    serde_json::to_string(&result)
        .unwrap_or_else(|_| r#"{"ok":false,"error":"serialize failed","events":[]}"#.to_string())
}

/// Serialize the current engine state as JSON (the host's read model). This is the FULL snapshot, for cold
/// load; for ongoing persistence prefer [`take_state_delta`] so the cost scales with what changed.
pub fn get_state_json(engine: &Engine) -> String {
    serde_json::to_string(engine.store()).unwrap_or_else(|_| "{}".to_string())
}

/// Take the changes since the last call and CLEAR the dirty set: only the changed profiles + library
/// buckets (and the active id if it moved). The host upserts this into its persisted copy, so a write is
/// O(changed records), never O(total library size). The full snapshot is only needed on a cold load.
pub fn take_state_delta(engine: &mut Engine) -> StateDelta {
    let profiles: Vec<Profile> = engine
        .dirty
        .profiles
        .iter()
        .filter_map(|id| engine.store.roster.get(id).cloned())
        .collect();
    let libraries: BTreeMap<ProfileId, ProfileLibrary> = engine
        .dirty
        .libraries
        .iter()
        .filter_map(|id| engine.store.libraries.get(id).map(|lib| (id.clone(), lib.clone())))
        .collect();
    let active_profile_id = engine
        .dirty
        .active_changed
        .then(|| engine.store.active_profile_id.clone());
    engine.dirty.clear();
    StateDelta {
        active_profile_id,
        profiles,
        libraries,
    }
}

/// The FFI entry point for incremental persistence: serialize the changed records and clear the dirty set.
/// `{}` when nothing changed.
pub fn get_state_delta_json(engine: &mut Engine) -> String {
    serde_json::to_string(&take_state_delta(engine)).unwrap_or_else(|_| "{}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::InMemoryEnv;
    use vortx_state::ProfileId;

    fn env() -> InMemoryEnv {
        InMemoryEnv::new(1000)
    }

    #[test]
    fn init_seeds_owner_active() {
        let engine = init_runtime("owner", "Owner");
        assert_eq!(engine.store().active_profile_id, ProfileId::new("owner"));
        assert!(engine.store().active_profile().unwrap().owner);
    }

    #[test]
    fn delta_carries_only_the_changed_records_and_clears() {
        // Seed many profiles so a full snapshot would be large; one edit must yield a 1-record delta.
        let mut engine = init_runtime("owner", "Owner");
        for i in 0..50 {
            dispatch(&mut engine, Action::AddProfile { id: format!("p{i}"), name: "P".into() }, &env());
        }
        // Persist everything once, then clear by taking the delta.
        let _ = take_state_delta(&mut engine);
        assert!(!engine.has_pending_changes());

        // A single edit -> the delta has exactly that one profile, not all 51.
        dispatch(&mut engine, Action::SetParental { id: "p7".into(), kids: true, maturity_ceiling: None }, &env());
        let delta = take_state_delta(&mut engine);
        assert_eq!(delta.profiles.len(), 1); // O(changed), not O(total)
        assert_eq!(delta.profiles[0].id, ProfileId::new("p7"));
        assert!(delta.profiles[0].parental.kids);
        assert!(delta.active_profile_id.is_none()); // active did not move

        // Taking again yields an empty delta (dirty was cleared).
        let empty = take_state_delta(&mut engine);
        assert!(empty.profiles.is_empty() && empty.libraries.is_empty());
        assert!(!engine.has_pending_changes());
    }

    #[test]
    fn switch_marks_active_and_its_library_in_the_delta() {
        let mut engine = init_runtime("owner", "Owner");
        dispatch(&mut engine, Action::AddProfile { id: "kid".into(), name: "Kid".into() }, &env());
        let _ = take_state_delta(&mut engine);

        dispatch(&mut engine, Action::SwitchProfile { id: "kid".into() }, &env());
        let delta = take_state_delta(&mut engine);
        assert_eq!(delta.active_profile_id, Some(ProfileId::new("kid")));
        assert!(delta.libraries.contains_key(&ProfileId::new("kid")));
        assert!(delta.profiles.is_empty()); // switching does not change a profile record
    }

    #[test]
    fn delta_json_round_trips_and_applies_like_the_full_state() {
        let mut engine = init_runtime("owner", "Owner");
        dispatch(&mut engine, Action::AddProfile { id: "kid".into(), name: "Kid".into() }, &env());
        let json = get_state_delta_json(&mut engine);
        let back: StateDelta = serde_json::from_str(&json).unwrap();
        assert_eq!(back.profiles.len(), 1);
        assert_eq!(back.profiles[0].id, ProfileId::new("kid"));
    }

    #[test]
    fn add_then_switch_repoints_active() {
        let mut engine = init_runtime("owner", "Owner");
        let r = dispatch(
            &mut engine,
            Action::AddProfile {
                id: "kid".into(),
                name: "Kid".into(),
            },
            &env(),
        );
        assert!(r.ok);
        let r = dispatch(
            &mut engine,
            Action::SwitchProfile { id: "kid".into() },
            &env(),
        );
        assert_eq!(
            r.events,
            vec![EngineEvent::ProfileSwitched { id: "kid".into() }]
        );
        assert_eq!(engine.store().active_profile_id, ProfileId::new("kid"));
    }

    #[test]
    fn switch_to_unknown_is_a_clean_failure() {
        let mut engine = init_runtime("owner", "Owner");
        let r = dispatch(
            &mut engine,
            Action::SwitchProfile { id: "ghost".into() },
            &env(),
        );
        assert!(!r.ok);
        assert_eq!(r.error.as_deref(), Some("profile not found"));
    }

    #[test]
    fn deleting_the_owner_is_refused() {
        let mut engine = init_runtime("owner", "Owner");
        let r = dispatch(
            &mut engine,
            Action::DeleteProfile { id: "owner".into() },
            &env(),
        );
        assert!(!r.ok);
        assert_eq!(r.error.as_deref(), Some("cannot delete the owner profile"));
    }

    #[test]
    fn malformed_action_json_is_a_clean_failure_not_a_panic() {
        let mut engine = init_runtime("owner", "Owner");
        let out = dispatch_json(&mut engine, "not json", &env());
        let parsed: DispatchResult = serde_json::from_str(&out).unwrap();
        assert!(!parsed.ok);
        assert!(parsed.error.is_some());
    }

    #[test]
    fn get_state_json_round_trips_to_the_store() {
        let engine = init_runtime("owner", "Owner");
        let json = get_state_json(&engine);
        let back: VortxStore = serde_json::from_str(&json).unwrap();
        assert_eq!(&back, engine.store());
    }
}
