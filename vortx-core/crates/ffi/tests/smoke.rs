//! The Phase 4 smoke proof, driven through the extern C surface exactly as a platform bridge
//! drives it: init a runtime, dispatch a JSON action, pull full state and the delta, run the
//! resolve surface for a meta, free every string, free the engine. Every returned pointer is
//! freed through `vortx_string_free` (the CString round trip), and the churn test hammers the
//! init / free cycle to surface double-free or use-after-free crashes under the harness.

use std::ffi::{c_char, CStr, CString};
use std::ptr;

use serde_json::Value;
use vortx_ffi::{
    vortx_dispatch_json, vortx_engine_free, vortx_get_state_delta_json, vortx_get_state_json,
    vortx_init_runtime, vortx_resolve_json, vortx_string_free,
};

/// Build a NUL-terminated C string for a call argument.
fn cs(s: &str) -> CString {
    CString::new(s).expect("test input contains no interior NUL")
}

/// Copy an engine-owned C string into Rust and free it through the ABI (the ownership contract:
/// every returned `char*` is freed exactly once with `vortx_string_free`).
///
/// # Safety
/// `ptr` must be a live pointer returned by a `vortx_*` function.
unsafe fn read_and_free(ptr: *mut c_char) -> String {
    assert!(!ptr.is_null(), "engine returned a null string");
    let copied = CStr::from_ptr(ptr)
        .to_str()
        .expect("engine JSON is UTF-8")
        .to_string();
    vortx_string_free(ptr);
    copied
}

#[test]
fn c_abi_round_trip_dispatch_state_delta_resolve() {
    unsafe {
        let engine = vortx_init_runtime(cs("owner").as_ptr(), cs("Owner").as_ptr());
        assert!(!engine.is_null(), "init returned a handle");

        // Dispatch one JSON action at host time 1000.
        let action = cs(r#"{"type":"add_profile","id":"kid","name":"Kid"}"#);
        let dispatched = read_and_free(vortx_dispatch_json(engine, action.as_ptr(), 1000));
        let dispatched: Value = serde_json::from_str(&dispatched).expect("dispatch JSON parses");
        assert_eq!(dispatched["ok"], true);

        // Full state pull carries the new profile.
        let state = read_and_free(vortx_get_state_json(engine));
        let state: Value = serde_json::from_str(&state).expect("state JSON parses");
        assert!(state.to_string().contains("kid"));

        // The delta carries only the change, then clears.
        let delta = read_and_free(vortx_get_state_delta_json(engine));
        assert!(delta.contains("kid"));
        let drained = read_and_free(vortx_get_state_delta_json(engine));
        assert!(!drained.contains("kid"), "dirty set cleared: {drained}");

        // The resolve surface for a meta: plan the stream fan-out (stream_load), empty registry,
        // then rank a direct streams request. Both come back well-formed through C.
        // Snapshot fields are serde-defaulted, so the minimal planning request is just the
        // resource path + the host clock (empty registry: an empty, well-formed plan).
        let plan_req = cs(
            r#"{"kind":"stream_load","req":{"kind":"stream","type":"movie","id":"tt0468569"},"now":1000}"#,
        );
        let plan = read_and_free(vortx_resolve_json(engine, plan_req.as_ptr()));
        let plan: Value = serde_json::from_str(&plan).expect("plan JSON parses");
        assert_eq!(plan["kind"], "stream_load_plan", "got: {plan}");

        let streams_req =
            cs(r#"{"kind":"streams","streams":[{"name":"2160p WEB-DL"}],"cached":[true]}"#);
        let streams = read_and_free(vortx_resolve_json(engine, streams_req.as_ptr()));
        let streams: Value = serde_json::from_str(&streams).expect("streams JSON parses");
        assert_eq!(streams["kind"], "streams");

        vortx_engine_free(engine);
    }
}

#[test]
fn null_and_bad_inputs_come_back_as_errors_not_crashes() {
    unsafe {
        // Null arguments to init: no handle, no crash.
        assert!(vortx_init_runtime(ptr::null(), cs("x").as_ptr()).is_null());
        assert!(vortx_init_runtime(cs("x").as_ptr(), ptr::null()).is_null());

        // Null engine everywhere: well-formed error / empty JSON.
        let out = read_and_free(vortx_dispatch_json(ptr::null_mut(), cs("{}").as_ptr(), 0));
        assert!(out.contains("null engine"));
        let out = read_and_free(vortx_resolve_json(ptr::null(), cs("{}").as_ptr()));
        assert!(out.contains("null engine"));
        let out = read_and_free(vortx_get_state_json(ptr::null()));
        assert_eq!(out, "{}");
        let out = read_and_free(vortx_get_state_delta_json(ptr::null_mut()));
        assert_eq!(out, "{}");

        // Non-UTF-8 and malformed action bytes: error result, never a panic across the boundary.
        let engine = vortx_init_runtime(cs("owner").as_ptr(), cs("Owner").as_ptr());
        let bad_utf8 = CString::new(vec![0xff, 0xfe]).expect("bytes contain no NUL");
        let out = read_and_free(vortx_dispatch_json(engine, bad_utf8.as_ptr(), 0));
        assert!(out.contains("\"ok\":false"));
        let out = read_and_free(vortx_dispatch_json(engine, cs("not json").as_ptr(), 0));
        assert!(out.contains("\"ok\":false"));

        // Frees are null-safe no-ops.
        vortx_string_free(ptr::null_mut());
        vortx_engine_free(ptr::null_mut());
        vortx_engine_free(engine);
    }
}

#[test]
fn init_free_churn_does_not_crash() {
    // 100 full create / dispatch / free cycles: gross leaks of the handle or a double free would
    // crash or trip the allocator here.
    unsafe {
        for i in 0..100 {
            let engine = vortx_init_runtime(cs("owner").as_ptr(), cs("Owner").as_ptr());
            assert!(!engine.is_null());
            let action = cs(&format!(
                r#"{{"type":"add_profile","id":"p{i}","name":"P"}}"#
            ));
            let out = read_and_free(vortx_dispatch_json(engine, action.as_ptr(), i));
            assert!(out.contains("\"ok\":true"));
            vortx_engine_free(engine);
        }
    }
}

#[cfg(feature = "host")]
mod host_seams {
    use super::{cs, read_and_free};
    use serde_json::Value;
    use vortx_ffi::host::vortx_host_resolve_json;

    /// A scratch directory under the system temp root, removed on drop.
    struct TempDir(std::path::PathBuf);

    impl TempDir {
        fn new(tag: &str) -> Self {
            let dir =
                std::env::temp_dir().join(format!("vortx-ffi-smoke-{tag}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).expect("create temp dir");
            TempDir(dir)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn host_resolve_replays_the_embedded_fixture_byte_identically() {
        unsafe {
            // No addons, no replayDir: the embedded fixture replays, hermetic and deterministic.
            let request = cs(r#"{"meta":"tt0468569","type":"movie"}"#);
            let first = read_and_free(vortx_host_resolve_json(request.as_ptr()));
            let second = read_and_free(vortx_host_resolve_json(request.as_ptr()));
            assert_eq!(
                first.as_bytes(),
                second.as_bytes(),
                "two rounds through C are byte-identical"
            );

            let doc: Value = serde_json::from_str(&first).expect("resolve document parses");
            assert_eq!(doc["schema"], "vortx-host-cli/resolve/1");
            let streams = doc["streams"].as_array().expect("streams array");
            assert!(!streams.is_empty(), "ranked streams came back");
            assert!(streams[0]["cacheStatus"]["state"].is_string());
            let url = doc["resolve"]["resolvedUrl"]
                .as_str()
                .expect("resolved url");
            assert!(
                url.starts_with("https://"),
                "direct https resolution: {url}"
            );
        }
    }

    #[test]
    fn host_resolve_persists_the_circuit_snapshot_through_the_storage_seam() {
        unsafe {
            let state = TempDir::new("state");
            let request = cs(&format!(
                r#"{{"meta":"tt0468569","stateDir":{}}}"#,
                serde_json::to_string(&state.0).expect("path encodes")
            ));
            let first = read_and_free(vortx_host_resolve_json(request.as_ptr()));
            assert_eq!(
                serde_json::from_str::<Value>(&first).expect("parses")["schema"],
                "vortx-host-cli/resolve/1"
            );
            // The FileStorage seam wrote the circuit snapshot into the state dir.
            let entries = std::fs::read_dir(&state.0).expect("state dir").count();
            assert!(entries > 0, "circuit snapshot persisted");
            // A second round reads the persisted snapshot back and still resolves.
            let second = read_and_free(vortx_host_resolve_json(request.as_ptr()));
            assert_eq!(
                serde_json::from_str::<Value>(&second).expect("parses")["schema"],
                "vortx-host-cli/resolve/1"
            );
        }
    }

    #[test]
    fn host_resolve_rejects_bad_requests_with_the_error_envelope() {
        unsafe {
            let out = read_and_free(vortx_host_resolve_json(std::ptr::null()));
            assert!(out.contains("\"kind\":\"error\""), "null request: {out}");
            let out = read_and_free(vortx_host_resolve_json(cs("not json").as_ptr()));
            assert!(out.contains("\"kind\":\"error\""), "bad json: {out}");
            let out = read_and_free(vortx_host_resolve_json(cs(r#"{"meta":""}"#).as_ptr()));
            assert!(out.contains("\"kind\":\"error\""), "empty meta: {out}");
            let out = read_and_free(vortx_host_resolve_json(
                cs(r#"{"meta":"tt1","services":["notaservice"]}"#).as_ptr(),
            ));
            assert!(out.contains("\"kind\":\"error\""), "unknown service: {out}");
        }
    }
}
