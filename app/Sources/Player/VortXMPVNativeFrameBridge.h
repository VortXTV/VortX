// Host ABI mirror of scripts/mpv-ios-native-pip-frame.patch, version 1.
// Deliberately does not require a future vendor header to build against today's SDK.
#ifndef VORTX_MPV_NATIVE_FRAME_BRIDGE_H
#define VORTX_MPV_NATIVE_FRAME_BRIDGE_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t abi_version;
    uint32_t reason;
    uint64_t subscription;
    uint64_t owner;
    uint64_t file_epoch;
    uint64_t timeline_epoch;
    uint64_t frame_id;
    uint64_t lease;
    void *pixel_buffer;
    double media_pts;
    double media_duration;
    double media_rate;
    uint64_t host_deadline_ns;
    uint64_t host_observed_ns;
    bool paused;
} VortXMPVNativeFrame;

typedef void (*VortXMPVNativeFrameCallback)(void *, void *, const VortXMPVNativeFrame *);
typedef void (*VortXMPVNativeFrameDestroy)(void *);

// False with the shipped vendor3 artifact. No fallback player or renderer is created.
bool VortXMPVNativeFramesAvailable(void);
int VortXMPVNativeSubscribe(void *mpv, uint64_t owner,
    VortXMPVNativeFrameCallback callback, VortXMPVNativeFrameDestroy destroy,
    void *context, void **session, uint64_t *subscription);
void VortXMPVNativeRetain(void *session);
void VortXMPVNativeRelease(void *session);
void VortXMPVNativeDetach(void *session, uint64_t subscription);
bool VortXMPVNativeIsCurrent(void *session, uint64_t lease);
void VortXMPVNativeReleaseFrame(void *session, uint64_t lease);
int VortXMPVNativeReason(void *session);
int VortXMPVNativeSetHeadless(void *mpv, void *session, uint64_t subscription, bool headless);
void VortXMPVNativeSetForeground(void *mpv, bool foreground);
#ifdef __cplusplus
}
#endif
#endif
