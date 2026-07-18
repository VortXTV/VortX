//! # vortx-ffi
//!
//! Phase 4 of the engine cutover: the linkable C ABI crate the platform apps link. Built as a
//! staticlib (the Apple xcframework slices link it into the Swift bridge, like the shipping
//! `stremiox-core` bridge) and a cdylib (the Android JNI / desktop shared object).
//!
//! ## The 7-symbol contract
//!
//! ```c
//! typedef struct VortxEngine VortxEngine;                  /* opaque handle */
//! VortxEngine* vortx_init_runtime(const char* owner_id, const char* owner_name);
//! char* vortx_dispatch_json(VortxEngine*, const char* action_json, uint64_t now_unix);
//! char* vortx_resolve_json(const VortxEngine*, const char* request_json);
//! char* vortx_get_state_json(const VortxEngine*);
//! char* vortx_get_state_delta_json(VortxEngine*);
//! void  vortx_string_free(char*);
//! void  vortx_engine_free(VortxEngine*);
//! ```
//!
//! These seven symbols are DEFINED once, in [`vortx_engine::ffi`] (the kernel's own extern C
//! marshalling layer, conformance-pinned against the pure JSON contracts), and re-exported here.
//! They are deliberately not redefined in this crate: two `#[no_mangle]` definitions of the same
//! symbol in one crate graph are a duplicate-symbol link error, and the kernel keeps its ABI next
//! to the JSON contracts it marshals. This crate is the packaging boundary: it turns those symbols
//! into artifacts the linkers consume (`libvortx_ffi.a`, `libvortx_ffi.dylib` / `.so`) and adds the
//! host seam entry below.
//!
//! ## The host seam entry (`host` feature, on by default)
//!
//! ```c
//! char* vortx_host_resolve_json(const char* request_json);  /* free with vortx_string_free */
//! ```
//!
//! The kernel handle is PURE by design: no clock, no network, no disk. The Phase 1 host seams
//! (Fetch / Env / Storage) therefore initialize in this crate, not inside `vortx_init_runtime`:
//! [`vortx_host_resolve_json`](host::vortx_host_resolve_json) builds
//! `vortx_host_native::NativeFetcher` (the Fetch seam), takes the clock through
//! `vortx_host_native::SystemEnv` (the Env seam), persists the circuit-breaker snapshot through
//! `vortx_host_native::FileStorage` (the Storage seam), and drives the exact plan -> fetch ->
//! settle -> rank round the Phase 3 proof (`vortx-host-cli`) pinned byte-stable. Hosts that own
//! their networking (the Swift and Kotlin bridges use URLSession / OkHttp) skip it and drive
//! `vortx_resolve_json` directly with `stream_load` / `settle_streams` queries.
//!
//! ## Memory ownership
//!
//! - Every `char*` a `vortx_*` function returns is heap-owned by this library (a `CString` moved
//!   out with `into_raw`) and MUST be freed exactly once with `vortx_string_free`. It is never
//!   freed by the C allocator.
//! - The `VortxEngine*` handle is a `Box` moved out with `Box::into_raw`; free it exactly once
//!   with `vortx_engine_free`. Both free functions are null-safe no-ops.
//! - Input strings stay caller-owned; the library only borrows them for the duration of the call.
//!
//! ## Thread model
//!
//! The `Engine` handle is plain data (no interior mutability, no raw pointers), so it is `Send` +
//! `Sync` and may be created on one thread and used from another. The contract the hosts follow is
//! ONE CALL AT A TIME per handle: `vortx_dispatch_json` and `vortx_get_state_delta_json` mutate
//! through the pointer, so overlapping any call with them is a data race. The Swift bridge
//! serializes on a worker queue (the same discipline as the shipping `stremiox_core_*` bridge);
//! JNI hosts wrap the handle in a mutex. `send_sync_proof` pins the `Send + Sync` claim at compile
//! time. There is no background thread and no `on_event` callback: the kernel is synchronous, so
//! dispatch RETURNS its events in the `DispatchResult` JSON and state changes are pulled with
//! `vortx_get_state_delta_json` (pull, not push; nothing outlives the call).
//!
//! ## Panic policy
//!
//! The kernel symbols are total over their inputs (null / non-UTF-8 / malformed JSON come back as
//! well-formed error JSON, proven by the kernel's own FFI tests and re-proven in `tests/smoke.rs`).
//! `vortx_host_resolve_json` does real I/O, so it additionally wraps the whole call in
//! `catch_unwind`: a Rust panic never unwinds across the C boundary (that would be UB), it comes
//! back as `{"kind":"error","error":"..."}`. Shipping Apple slices are built `panic = "abort"`
//! (`-Z build-std=std,panic_abort`, see `scripts/build-ffi-xcframework.sh`), which forecloses
//! unwind-across-FFI at the artifact level as well.

#[cfg(feature = "host")]
pub mod host;

// The kernel's extern C surface: the 7 contract symbols plus the Rust-visible marshalling seam.
// Re-exported so `vortx_ffi::vortx_dispatch_json` is the one path hosts and tests name, while the
// `#[no_mangle]` definitions stay with the kernel contracts they marshal.
pub use vortx_engine::ffi::{
    vortx_dispatch_json, vortx_engine_free, vortx_get_state_delta_json, vortx_get_state_json,
    vortx_init_runtime, vortx_resolve_json, vortx_string_free,
};
pub use vortx_engine::Engine;

/// Compile-time proof of the documented thread model: the handle is plain data, movable and
/// shareable across threads (mutation still requires the one-call-at-a-time discipline above).
const fn send_sync_proof<T: Send + Sync>() {}
const _: () = send_sync_proof::<Engine>();
