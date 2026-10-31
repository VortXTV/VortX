#ifndef VORTX_CAPTURE_FIXTURE_V2_H
#define VORTX_CAPTURE_FIXTURE_V2_H

/* Controlled C replies for the v2 capture test. This is not a libmpv/player fixture. */
#include <mpv/client.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

mpv_handle *vortx_capture_fixture_v2_create(int scenario);
void vortx_capture_fixture_v2_destroy(mpv_handle *handle);
uint64_t vortx_capture_fixture_v2_node_allocations(const mpv_handle *handle);
uint64_t vortx_capture_fixture_v2_node_frees(const mpv_handle *handle);
uint64_t vortx_capture_fixture_v2_string_allocations(const mpv_handle *handle);
uint64_t vortx_capture_fixture_v2_string_frees(const mpv_handle *handle);
int vortx_capture_fixture_v2_allocations_balanced(const mpv_handle *handle);

#ifdef __cplusplus
}
#endif

#endif
