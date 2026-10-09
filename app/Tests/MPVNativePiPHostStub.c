// Inert ABI double: no libmpv, decoder, GPU, network, audio, or AVKit runtime.
#include "MPVNativePiPHostStub.h"
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdlib.h>
#include <string.h>

struct session {
    int refs;
    bool closed;
    uint64_t owner, cookie, next_lease, timeline_epoch;
    VortXMPVNativeFrameCallback callback;
    VortXMPVNativeFrameDestroy destroy;
    void *context;
    struct { uint64_t id, timeline_epoch; void *pixels; } slots[2];
};
static struct session *current;
static int outstanding, destroys, modes, foreground_calls, mode_result;
void mpv_vortx_apple_frame_retain(void *p) { ((struct session *)p)->refs++; }
void mpv_vortx_apple_frame_release(void *p) {
    struct session *s = p;
    assert(s->refs > 0);
    if (!--s->refs) free(s);
}
void mpv_vortx_apple_frame_detach(void *p, uint64_t cookie) {
    struct session *s = p;
    if (s->cookie == cookie && !s->closed) {
        s->closed = true;
        if (s->destroy) { destroys++; s->destroy(s->context); }
        s->callback = NULL; s->destroy = NULL; s->context = NULL;
    }
}
bool mpv_vortx_apple_frame_is_current(void *p, uint64_t lease) {
    struct session *s = p;
    if (s->closed || !lease) return false;
    for (int i = 0; i < 2; i++)
        if (s->slots[i].id == lease)
            return s->slots[i].timeline_epoch == s->timeline_epoch;
    return false;
}
void mpv_vortx_apple_frame_release_frame(void *p, uint64_t lease) {
    struct session *s = p;
    for (int i = 0; i < 2; i++) if (s->slots[i].id == lease) {
        CFRelease(s->slots[i].pixels);
        s->slots[i].id = 0; s->slots[i].pixels = NULL;
        outstanding--;
        mpv_vortx_apple_frame_release(s);
        return;
    }
}
int mpv_vortx_apple_frame_reason(void *p) { return ((struct session *)p)->closed ? 10 : 0; }
int mpv_vortx_apple_frame_subscribe(void *mpv, uint64_t owner,
    VortXMPVNativeFrameCallback callback, VortXMPVNativeFrameDestroy destroy,
    void *context, void **out, uint64_t *cookie) {
    (void)mpv;
    assert(!current);
    current = calloc(1, sizeof(*current));
    current->refs = 2; // core and returned host session
    current->owner = owner; current->cookie = 1;
    current->timeline_epoch = 1;
    current->callback = callback; current->destroy = destroy; current->context = context;
    *out = current; *cookie = 1;
    return 0;
}
int mpv_vortx_apple_frame_set_headless(void *m, void *p, uint64_t c, bool h) {
    (void)m; (void)c; (void)h;
    modes++;
    return ((struct session *)p)->closed ? 2 : mode_result;
}
void mpv_vortx_apple_frame_set_foreground(void *m, bool f) { (void)m; (void)f; foreground_calls++; }
void TestNativeSetModeResult(int result) { mode_result = result; }
void TestNativeAdvanceEpoch(uint64_t epoch) {
    assert(current && epoch >= current->timeline_epoch);
    current->timeline_epoch = epoch;
}
int TestNativeOutstandingFrames(void) { return outstanding; }
int TestNativeDestroyCalls(void) { return destroys; }
int TestNativeModeCalls(void) { return modes; }
int TestNativeForegroundCalls(void) { return foreground_calls; }
void TestNativeReset(void) {
    assert(outstanding == 0);
    if (current) {
        mpv_vortx_apple_frame_detach(current, current->cookie);
        mpv_vortx_apple_frame_release(current);
        current = NULL;
    }
    destroys = modes = foreground_calls = mode_result = 0;
}
void TestNativePublish(void *pixels, double pts, double rate, bool paused, uint64_t epoch) {
    assert(current && !current->closed && current->callback);
    int i = current->slots[0].id == 0 ? 0 : current->slots[1].id == 0 ? 1 : -1;
    if (i < 0) return;
    uint64_t id = ++current->next_lease;
    if (epoch > current->timeline_epoch) current->timeline_epoch = epoch;
    current->slots[i].id = id;
    current->slots[i].timeline_epoch = epoch;
    current->slots[i].pixels = (void *)CFRetain(pixels);
    outstanding++;
    mpv_vortx_apple_frame_retain(current);
    VortXMPVNativeFrame frame = {
        .abi_version = 1, .owner = current->owner, .subscription = current->cookie,
        .file_epoch = 1, .timeline_epoch = epoch, .frame_id = id, .lease = id,
        .pixel_buffer = pixels, .media_pts = pts, .media_duration = 0.04,
        .media_rate = rate, .paused = paused,
        .host_observed_ns = 1000000000, .host_deadline_ns = paused ? 0 : 1000000000,
    };
    current->callback(current->context, current, &frame);
}
