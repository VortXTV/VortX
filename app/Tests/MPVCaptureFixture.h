#ifndef VORTX_CAPTURE_FIXTURE_H
#define VORTX_CAPTURE_FIXTURE_H

/*
 * Controlled C test surface.  The production Swift source imports
 * the exact canonical libmpv client API below; this header adds only a fake
 * handle factory and observable ownership counters.  It is not a live-player
 * or native-capability proof and must never be installed as a Libmpv header.
 */
#include <mpv/client.h>

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

mpv_handle *vortx_capture_fixture_create(int scenario);
void vortx_capture_fixture_destroy(mpv_handle *handle);

/* These counters are read before destroy so a test cannot hide a leak in the
 * fixture teardown.  mpv node and returned-string allocations are owned by
 * the fake API and freed only through the canonical mpv release functions. */
uint64_t vortx_capture_fixture_node_allocations(const mpv_handle *handle);
uint64_t vortx_capture_fixture_node_frees(const mpv_handle *handle);
uint64_t vortx_capture_fixture_string_allocations(const mpv_handle *handle);
uint64_t vortx_capture_fixture_string_frees(const mpv_handle *handle);
int vortx_capture_fixture_allocations_balanced(const mpv_handle *handle);

#ifdef __cplusplus
}
#endif

#endif /* VORTX_CAPTURE_FIXTURE_H */
