//! # vortx-engine
//!
//! The engine FFI shell: the thin, pure dispatch core every platform bridge calls. The Swift, Kotlin, and
//! web layers do not reimplement engine logic; they marshal JSON in and out of three functions:
//!
//! - [`init_runtime`] builds an [`Engine`] over the first-class multi-profile `VortxStore` (the structural
//!   break from stremio-core's single account `Ctx`).
//! - [`dispatch_json`] applies one JSON [`Action`] and returns a JSON [`DispatchResult`] with the
//!   [`EngineEvent`]s it produced. A malformed action yields a clean `{ ok: false, error }`, never a panic.
//! - [`get_state_json`] serializes the current state as the host's read model.
//!
//! This is the seam the extern C / JNI / wasm wrappers wrap in a later phase. Resource resolution (routing
//! requests into the source / debrid / ranking / playback crates) and the EventSink subscription model
//! join `dispatch` next; this first chunk locks the profile-action contract end to end.

mod action;
mod engine;
mod env;
pub mod ffi;
mod resolve;

pub use action::{Action, DispatchResult, EngineEvent};
pub use engine::{
    dispatch, dispatch_json, get_state_delta_json, get_state_json, init_runtime, take_state_delta,
    Engine, StateDelta,
};
pub use env::{Env, InMemoryEnv};
pub use resolve::{resolve, resolve_json, ResolveRequest, ResolveResponse};
