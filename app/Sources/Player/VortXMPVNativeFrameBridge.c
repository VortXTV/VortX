#include "VortXMPVNativeFrameBridge.h"

// Weak imports permit the host UI to explain that the native ABI is missing.
// Once built, subscribe/set_headless/set_foreground live in client.c, the same
// archive member as the already strongly linked mpv_create. They therefore do
// not rely on dlsym discovering an otherwise dead-stripped archive member.
#define OPTIONAL __attribute__((weak_import))
extern void mpv_vortx_apple_frame_retain(void *) OPTIONAL;
extern void mpv_vortx_apple_frame_release(void *) OPTIONAL;
extern void mpv_vortx_apple_frame_detach(void *, uint64_t) OPTIONAL;
extern bool mpv_vortx_apple_frame_is_current(void *, uint64_t) OPTIONAL;
extern void mpv_vortx_apple_frame_release_frame(void *, uint64_t) OPTIONAL;
extern int mpv_vortx_apple_frame_reason(void *) OPTIONAL;
extern int mpv_vortx_apple_frame_subscribe(void *, uint64_t,
    VortXMPVNativeFrameCallback, VortXMPVNativeFrameDestroy, void *, void **, uint64_t *) OPTIONAL;
extern int mpv_vortx_apple_frame_set_headless(void *, void *, uint64_t, bool) OPTIONAL;
extern void mpv_vortx_apple_frame_set_foreground(void *, bool) OPTIONAL;

bool VortXMPVNativeFramesAvailable(void)
{
    return mpv_vortx_apple_frame_retain && mpv_vortx_apple_frame_release &&
        mpv_vortx_apple_frame_detach && mpv_vortx_apple_frame_is_current &&
        mpv_vortx_apple_frame_release_frame && mpv_vortx_apple_frame_reason &&
        mpv_vortx_apple_frame_subscribe && mpv_vortx_apple_frame_set_headless &&
        mpv_vortx_apple_frame_set_foreground;
}

int VortXMPVNativeSubscribe(void *mpv, uint64_t owner,
    VortXMPVNativeFrameCallback callback, VortXMPVNativeFrameDestroy destroy,
    void *context, void **session, uint64_t *subscription)
{
    if (!VortXMPVNativeFramesAvailable() || !mpv) return -1;
    return mpv_vortx_apple_frame_subscribe(mpv, owner, callback, destroy, context, session, subscription);
}
void VortXMPVNativeRetain(void *s) { if (s && VortXMPVNativeFramesAvailable()) mpv_vortx_apple_frame_retain(s); }
void VortXMPVNativeRelease(void *s) { if (s && VortXMPVNativeFramesAvailable()) mpv_vortx_apple_frame_release(s); }
void VortXMPVNativeDetach(void *s, uint64_t c) { if (s && VortXMPVNativeFramesAvailable()) mpv_vortx_apple_frame_detach(s, c); }
bool VortXMPVNativeIsCurrent(void *s, uint64_t l) { return s && VortXMPVNativeFramesAvailable() && mpv_vortx_apple_frame_is_current(s, l); }
void VortXMPVNativeReleaseFrame(void *s, uint64_t l) { if (s && VortXMPVNativeFramesAvailable()) mpv_vortx_apple_frame_release_frame(s, l); }
int VortXMPVNativeReason(void *s) { return s && VortXMPVNativeFramesAvailable() ? mpv_vortx_apple_frame_reason(s) : 10; }
int VortXMPVNativeSetHeadless(void *m, void *s, uint64_t c, bool h) { return m && s && VortXMPVNativeFramesAvailable() ? mpv_vortx_apple_frame_set_headless(m, s, c, h) : 10; }
void VortXMPVNativeSetForeground(void *m, bool f) { if (m && VortXMPVNativeFramesAvailable()) mpv_vortx_apple_frame_set_foreground(m, f); }
