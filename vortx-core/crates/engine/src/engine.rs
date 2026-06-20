//! The runtime and the dispatch core. `init_runtime` builds an [`Engine`] over the first-class
//! multi-profile [`VortxStore`]; `dispatch_json` applies one JSON [`Action`] and returns a JSON
//! [`DispatchResult`]; `get_state_json` serializes the state. These three are the exact shape the
//! platform FFI (extern C / JNI / wasm) wraps in a later phase; here they are pure Rust and fully
//! testable. Resource resolution (routing requests into the source / debrid / ranking crates) joins
//! `dispatch` in a later phase.

use vortx_state::{Profile, ProfileId, VortxStore};

use crate::action::{Action, DispatchResult, EngineEvent};
use crate::env::Env;

/// The engine runtime: the per-profile state plus (later) the source registry, caches, and players.
pub struct Engine {
    store: VortxStore,
}

impl Engine {
    /// The current engine state (read-only).
    pub fn store(&self) -> &VortxStore {
        &self.store
    }
}

/// Build a runtime seeded with the owner profile (active) and its empty library.
pub fn init_runtime(owner_id: &str, owner_name: &str) -> Engine {
    let mut owner = Profile::new(ProfileId::new(owner_id), owner_name);
    owner.owner = true;
    Engine {
        store: VortxStore::new(owner),
    }
}

/// Apply one typed action to the engine. Pure over `(state, action, env)`; never panics.
pub fn dispatch(engine: &mut Engine, action: Action, env: &dyn Env) -> DispatchResult {
    match action {
        Action::SwitchProfile { id } => {
            match engine.store.switch_profile(&ProfileId::new(id.clone())) {
                Ok(()) => DispatchResult::ok(vec![EngineEvent::ProfileSwitched { id }]),
                Err(e) => DispatchResult::err(e.to_string()),
            }
        }
        Action::AddProfile { id, name } => {
            engine
                .store
                .roster
                .upsert(Profile::new(ProfileId::new(id.clone()), name));
            DispatchResult::ok(vec![EngineEvent::ProfileAdded { id }])
        }
        Action::DeleteProfile { id } => {
            match engine
                .store
                .roster
                .delete(&ProfileId::new(id.clone()), env.now())
            {
                Ok(()) => DispatchResult::ok(vec![EngineEvent::ProfileDeleted { id }]),
                Err(e) => DispatchResult::err(e.to_string()),
            }
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

/// Serialize the current engine state as JSON (the host's read model).
pub fn get_state_json(engine: &Engine) -> String {
    serde_json::to_string(engine.store()).unwrap_or_else(|_| "{}".to_string())
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
