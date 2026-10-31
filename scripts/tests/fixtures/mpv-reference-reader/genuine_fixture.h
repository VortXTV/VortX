#ifndef VORTX_GENUINE_READER_FIXTURE_H
#define VORTX_GENUINE_READER_FIXTURE_H
#include <stdbool.h>
#include <stdint.h>
#include "demux/reference_reader.h"
struct demuxer;
struct vortx_reference_fixture_rig {
    void *opaque;
    const char *url;
    int (*serve_two)(void *, const char *, const char *);
    int (*finish)(void *);
};
unsigned genuine_http_case_count(void);
int vortx_reference_fixture_run_case(struct vortx_reference_fixture_rig *, unsigned);
bool fixture_real_reader_roundtrip(
    struct demuxer *, int, int64_t, void (*)(void *), void *,
    void (*)(void (*)(void *), void *), struct demux_reference_result *);
bool fixture_real_owner_reset_rejects(struct demuxer *,
                                    struct demux_reference_request *);
#endif
