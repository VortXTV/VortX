//! The extern-C ABI: the actual symbols the Swift (static link) and Kotlin/JNI (dynamic link) bridges
//! call. It is a thin marshalling layer over the pure JSON contracts (`dispatch_json`, `resolve_json`,
//! `get_state_json`), so the cross-language data shapes stay conformance-pinned by those vectors; this
//! layer only moves C strings and an opaque runtime handle across the boundary.
//!
//! # ABI
//!
//! ```c
//! typedef struct Engine Engine;                       // opaque handle
//! Engine* vortx_init_runtime(const char* owner_id, const char* owner_name);   // NULL on bad input
//! char*   vortx_dispatch_json(Engine*, const char* action_json, uint64_t now_unix); // owned JSON
//! char*   vortx_resolve_json(const Engine*, const char* request_json);              // owned JSON
//! char*   vortx_get_state_json(const Engine*);                                      // owned JSON (full)
//! char*   vortx_get_state_delta_json(Engine*);     // owned JSON: changed records only, clears dirty
//! void    vortx_string_free(char*);    // free a char* returned above
//! void    vortx_engine_free(Engine*);  // free the runtime
//! ```
//!
//! Ownership rules: every `char*` returned is heap-owned by the engine and MUST be freed exactly once with
//! `vortx_string_free`; the `Engine*` MUST be freed once with `vortx_engine_free`. `now_unix` is injected
//! by the host so the kernel needs no clock of its own (time enters only at this boundary).

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use crate::{
    dispatch_json, get_state_delta_json, get_state_json, init_runtime, resolve_json, Engine,
    InMemoryEnv,
};

/// Borrow a C string as `&str`. `None` on null or non-UTF-8.
///
/// # Safety
/// `ptr` must be null or a valid, NUL-terminated C string that outlives the borrow.
unsafe fn cstr<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: non-null per the check; caller guarantees a valid NUL-terminated string.
    CStr::from_ptr(ptr).to_str().ok()
}

/// Move a Rust `String` into a heap C string the caller frees with [`vortx_string_free`].
fn to_c(s: String) -> *mut c_char {
    // Our JSON never contains an interior NUL; if it somehow did, return a valid error string instead.
    CString::new(s)
        .unwrap_or_else(|_| CString::new(r#"{"error":"nul in output"}"#).unwrap())
        .into_raw()
}

/// Build a runtime over the owner profile. Returns NULL if either argument is null / non-UTF-8.
///
/// # Safety
/// `owner_id` and `owner_name` must each be null or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn vortx_init_runtime(
    owner_id: *const c_char,
    owner_name: *const c_char,
) -> *mut Engine {
    let (Some(id), Some(name)) = (cstr(owner_id), cstr(owner_name)) else {
        return ptr::null_mut();
    };
    Box::into_raw(Box::new(init_runtime(id, name)))
}

/// Apply one JSON action at host time `now`. Returns an owned JSON `DispatchResult` string (a null engine
/// or non-UTF-8 action yields a well-formed error result, never a crash).
///
/// # Safety
/// `engine` must be a pointer from [`vortx_init_runtime`] that has not been freed; `action_json` must be
/// null or a valid NUL-terminated C string. The returned pointer must be freed with [`vortx_string_free`].
#[no_mangle]
pub unsafe extern "C" fn vortx_dispatch_json(
    engine: *mut Engine,
    action_json: *const c_char,
    now: u64,
) -> *mut c_char {
    // SAFETY: per the contract `engine` is a live pointer from vortx_init_runtime or null.
    let Some(engine) = engine.as_mut() else {
        return to_c(r#"{"ok":false,"error":"null engine","events":[]}"#.to_string());
    };
    let Some(action) = cstr(action_json) else {
        return to_c(r#"{"ok":false,"error":"null or non-utf8 action","events":[]}"#.to_string());
    };
    let env = InMemoryEnv::new(now);
    to_c(dispatch_json(engine, action, &env))
}

/// Resolve one JSON request (read-only). Returns an owned JSON `ResolveResponse` string.
///
/// # Safety
/// `engine` must be a live pointer from [`vortx_init_runtime`]; `request_json` must be null or a valid
/// NUL-terminated C string. The returned pointer must be freed with [`vortx_string_free`].
#[no_mangle]
pub unsafe extern "C" fn vortx_resolve_json(
    engine: *const Engine,
    request_json: *const c_char,
) -> *mut c_char {
    // SAFETY: per the contract `engine` is a live pointer from vortx_init_runtime or null.
    let Some(engine) = engine.as_ref() else {
        return to_c(r#"{"kind":"error","error":"null engine"}"#.to_string());
    };
    let Some(req) = cstr(request_json) else {
        return to_c(r#"{"kind":"error","error":"null or non-utf8 request"}"#.to_string());
    };
    to_c(resolve_json(engine, req))
}

/// Serialize the current state as JSON (the host read model).
///
/// # Safety
/// `engine` must be a live pointer from [`vortx_init_runtime`]. The returned pointer must be freed with
/// [`vortx_string_free`].
#[no_mangle]
pub unsafe extern "C" fn vortx_get_state_json(engine: *const Engine) -> *mut c_char {
    // SAFETY: per the contract `engine` is a live pointer from vortx_init_runtime or null.
    match engine.as_ref() {
        Some(engine) => to_c(get_state_json(engine)),
        None => to_c("{}".to_string()),
    }
}

/// Take the changed records since the last call (incremental persistence) as JSON, clearing the dirty
/// set. `{}` when nothing changed. Prefer this over `vortx_get_state_json` for ongoing writes: the cost
/// scales with what changed, not with total library size.
///
/// # Safety
/// `engine` must be a live pointer from [`vortx_init_runtime`]. The returned pointer must be freed with
/// [`vortx_string_free`].
#[no_mangle]
pub unsafe extern "C" fn vortx_get_state_delta_json(engine: *mut Engine) -> *mut c_char {
    // SAFETY: per the contract `engine` is a live pointer from vortx_init_runtime or null.
    match engine.as_mut() {
        Some(engine) => to_c(get_state_delta_json(engine)),
        None => to_c("{}".to_string()),
    }
}

/// Free a string returned by any `vortx_*_json` function. Safe to call with null.
///
/// # Safety
/// `s` must be null or a pointer returned by a `vortx_*_json` function, freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn vortx_string_free(s: *mut c_char) {
    if !s.is_null() {
        // SAFETY: per the contract `s` came from CString::into_raw in to_c and is freed once.
        drop(CString::from_raw(s));
    }
}

/// Free a runtime returned by [`vortx_init_runtime`]. Safe to call with null.
///
/// # Safety
/// `engine` must be null or a pointer from [`vortx_init_runtime`], freed exactly once.
#[no_mangle]
pub unsafe extern "C" fn vortx_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        // SAFETY: per the contract `engine` came from Box::into_raw in vortx_init_runtime and is freed once.
        drop(Box::from_raw(engine));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cs(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    unsafe fn read_and_free(p: *mut c_char) -> String {
        assert!(!p.is_null());
        let s = CStr::from_ptr(p).to_str().unwrap().to_string();
        vortx_string_free(p);
        s
    }

    #[test]
    fn full_ffi_round_trip() {
        unsafe {
            let eng = vortx_init_runtime(cs("owner").as_ptr(), cs("Owner").as_ptr());
            assert!(!eng.is_null());

            let add = cs(r#"{"type":"add_profile","id":"kid","name":"Kid"}"#);
            let out = read_and_free(vortx_dispatch_json(eng, add.as_ptr(), 1000));
            assert!(out.contains("\"ok\":true"));
            assert!(out.contains("profile_added"));

            let req = cs(r#"{"kind":"streams","streams":[{"name":"2160p WEB-DL"}],"cached":[true]}"#);
            let res = read_and_free(vortx_resolve_json(eng, req.as_ptr()));
            assert!(res.contains("\"kind\":\"streams\""));

            let state = read_and_free(vortx_get_state_json(eng));
            assert!(state.contains("kid"));

            // Incremental persistence: the delta carries the added profile, then clears.
            let delta = read_and_free(vortx_get_state_delta_json(eng));
            assert!(delta.contains("kid"));
            let empty = read_and_free(vortx_get_state_delta_json(eng));
            assert!(!empty.contains("kid")); // dirty cleared

            vortx_engine_free(eng);
        }
    }

    #[test]
    fn null_pointers_yield_errors_not_crashes() {
        unsafe {
            assert!(vortx_init_runtime(ptr::null(), cs("x").as_ptr()).is_null());
            let out = read_and_free(vortx_dispatch_json(ptr::null_mut(), cs("{}").as_ptr(), 0));
            assert!(out.contains("null engine"));
            let res = read_and_free(vortx_resolve_json(ptr::null(), cs("{}").as_ptr()));
            assert!(res.contains("null engine"));
            vortx_string_free(ptr::null_mut()); // no-op, must not crash
            vortx_engine_free(ptr::null_mut()); // no-op, must not crash
        }
    }

    #[test]
    fn ffi_output_matches_in_process_dispatch() {
        // The FFI must be a faithful marshal: same input, byte-identical JSON to the in-process path.
        unsafe {
            let eng = vortx_init_runtime(cs("owner").as_ptr(), cs("Owner").as_ptr());
            let action = r#"{"type":"add_profile","id":"k","name":"K"}"#;
            let via_ffi = read_and_free(vortx_dispatch_json(eng, cs(action).as_ptr(), 1000));

            let mut direct = init_runtime("owner", "Owner");
            let via_direct = dispatch_json(&mut direct, action, &InMemoryEnv::new(1000));

            assert_eq!(via_ffi, via_direct);
            vortx_engine_free(eng);
        }
    }
}
