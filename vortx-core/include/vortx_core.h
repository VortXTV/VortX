// VortX engine core, C ABI for the Swift bridge. Maintained by hand; mirrors the ABI doc in
// vortx-core/crates/engine/src/ffi.rs (that doc comment is the source of truth). Seven symbols:
// init / dispatch / resolve / state / state-delta / string-free / engine-free.
//
// Ownership: every char* returned is heap-owned by the engine and MUST be freed exactly once with
// vortx_string_free; the engine handle MUST be freed exactly once with vortx_engine_free.
#ifndef VORTX_CORE_H
#define VORTX_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque engine runtime handle (the Rust `Engine`). The tag name is C-side only; the linked
// symbols below are what bind to the Rust staticlib.
typedef struct VortxEngine VortxEngine;

// Build a runtime over the owner profile. Returns NULL if either argument is null / non-UTF-8.
VortxEngine *vortx_init_runtime(const char *owner_id, const char *owner_name);

// Apply one JSON action at host time `now_unix` (unix SECONDS; the kernel has no clock of its
// own, time enters only here). Returns an owned JSON DispatchResult string, never NULL; a null
// engine or bad action yields a well-formed error JSON, not a crash.
char *vortx_dispatch_json(VortxEngine *engine, const char *action_json, uint64_t now_unix);

// Resolve one JSON request (read-only query: stream ranking, subtitle pick, parental gate, ...).
// Returns an owned JSON ResolveResponse string, never NULL; malformed input yields
// {"kind":"error",...} so the host parse stays total.
char *vortx_resolve_json(const VortxEngine *engine, const char *request_json);

// Serialize the full engine state as JSON (the host read model). Owned, never NULL.
char *vortx_get_state_json(const VortxEngine *engine);

// The records changed since the last call (incremental persistence), clearing the dirty set.
// "{}" when nothing changed. Owned, never NULL.
char *vortx_get_state_delta_json(VortxEngine *engine);

// Free a string returned by any vortx_*_json function above. Safe to call with NULL.
void vortx_string_free(char *s);

// Free a runtime returned by vortx_init_runtime. Safe to call with NULL.
void vortx_engine_free(VortxEngine *engine);

#ifdef __cplusplus
}
#endif

#endif /* VORTX_CORE_H */
