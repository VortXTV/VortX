// StremioX native core, C ABI for the Swift bridge. Maintained by hand; mirrors src/lib.rs.
// See docs/REBASE-stremio-core.md.
#ifndef STREMIOX_CORE_H
#define STREMIOX_CORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// stremio-core's storage schema version (smoke test that the engine links + calls).
uint32_t stremiox_core_schema_version(void);

// Callback invoked (on a background worker thread) for every RuntimeEvent, as JSON bytes,
// e.g. {"name":"NewState","args":["board","ctx"]}. `data` is valid ONLY for the duration of the
// call, copy it synchronously. `ctx` is the opaque pointer passed to stremiox_core_init.
typedef void (*StremioxEventCallback)(void *ctx, const uint8_t *data, size_t len);

// Hydrate persisted buckets, build the Runtime, and start the event loop.
//  storage_dir : directory for persisted buckets ({dir}/{key}.json), app sandbox, durable.
//  cache_dir   : directory for the HTTP cache, OS-purgeable Caches is fine.
//  ctx         : opaque pointer handed back to `on_event` (e.g. an unretained Swift object).
//  on_event    : RuntimeEvent sink.
// Returns true on success (or if already initialized).
bool stremiox_core_init(const char *storage_dir, const char *cache_dir, void *ctx,
                        StremioxEventCallback on_event);

// Dispatch an action: {"field": <field-name|null>, "action": <Action JSON>}.
void stremiox_core_dispatch(const char *action_json);

// Serialize a model field (JSON name, e.g. "board") to JSON. Caller owns the returned string and
// MUST free it with stremiox_core_string_free. Returns "null" if not ready / on error.
char *stremiox_core_get_state(const char *field_json);

// Free a string returned by stremiox_core_get_state.
void stremiox_core_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* STREMIOX_CORE_H */
