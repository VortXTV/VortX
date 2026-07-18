/*
 * vortx_ffi.h: the C ABI of the vortx-core engine (the vortx-ffi crate).
 *
 * Ownership contract:
 *   - Every char* a vortx_* function RETURNS is heap-owned by the engine library and MUST be
 *     freed exactly once with vortx_string_free (never with free()).
 *   - The VortxEngine* handle MUST be freed exactly once with vortx_engine_free.
 *   - Input strings stay caller-owned; the library only borrows them for the call.
 *   - Both free functions are null-safe no-ops.
 *
 * Thread contract: the handle may move between threads, but calls on ONE handle must not
 * overlap (dispatch and delta mutate it). Serialize on a queue or wrap in a mutex.
 *
 * Every payload in and out is UTF-8 JSON; malformed or null input yields a well-formed
 * error JSON (or NULL from init), never a crash.
 */
#ifndef VORTX_FFI_H
#define VORTX_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The opaque engine handle (a Rust Box behind the boundary). */
typedef struct VortxEngine VortxEngine;

/* Build a runtime seeded with the owner profile. NULL if either argument is NULL or not UTF-8. */
VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name);

/* Apply one JSON action at host time now_unix (seconds). Returns an owned DispatchResult JSON:
 * { "ok": bool, "error": string|null, "events": [...] }. */
char *vortx_dispatch_json(VortxEngine *engine, const char *action_json, uint64_t now_unix);

/* Resolve one JSON request (read-only): stream_load / settle_streams / streams / debrid / ...
 * Returns an owned response JSON tagged by "kind" ("error" on bad input). */
char *vortx_resolve_json(const VortxEngine *engine, const char *request_json);

/* Serialize the full current state as owned JSON (the host read model). */
char *vortx_get_state_json(const VortxEngine *engine);

/* Take the records changed since the last call as owned JSON, clearing the dirty set.
 * "{}" when nothing changed. Prefer this for ongoing persistence: cost scales with the change. */
char *vortx_get_state_delta_json(VortxEngine *engine);

/* Free a char* returned by any vortx_* function. Null-safe. */
void vortx_string_free(char *s);

/* Free the engine handle. Null-safe. */
void vortx_engine_free(VortxEngine *engine);

/* Host seam entry (present unless the crate was built without the `host` feature, e.g. wasm):
 * run one full plan -> fetch -> settle -> rank resolve round through the native host substrate
 * (NativeFetcher / SystemEnv / FileStorage). Request example:
 *   { "meta": "tt0468569", "type": "movie", "addons": [["id","https://..."]],
 *     "services": ["realdebrid"], "now": 0, "budgetMs": 5000, "stateDir": "/path" }
 * With no addons the embedded fixture replays deterministically. Returns the owned resolve
 * document JSON (schema vortx-host-cli/resolve/1) or {"kind":"error","error":"..."}.
 * Free with vortx_string_free. */
char *vortx_host_resolve_json(const char *request_json);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* VORTX_FFI_H */
