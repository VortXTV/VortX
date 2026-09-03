#include "VortXRemuxInputProbe.h"

#include <stdatomic.h>
#include <stdlib.h>

/* The app supports only Apple 64-bit architectures. A callback may not acquire a hidden lock. */
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "VortX remux probe requires lock-free int atomics");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "VortX remux probe requires lock-free 64-bit atomics");

struct VortXRemuxInputProbe {
    atomic_int cancelled;
    atomic_int open_in_flight;
    atomic_int opened;
    atomic_int stream_info_done;
    atomic_llong input_bytes_read;

    /* Producer-thread-only. The FFmpeg callback is invoked synchronously on that thread. */
    void *input_context;
};

VortXRemuxInputProbe *VortXRemuxInputProbeCreate(void) {
    VortXRemuxInputProbe *probe = calloc(1, sizeof(*probe));
    if (probe == NULL) return NULL;
    atomic_init(&probe->cancelled, 0);
    atomic_init(&probe->open_in_flight, 0);
    atomic_init(&probe->opened, 0);
    atomic_init(&probe->stream_info_done, 0);
    atomic_init(&probe->input_bytes_read, 0);
    return probe;
}

void VortXRemuxInputProbeDestroy(VortXRemuxInputProbe *probe) { free(probe); }

void VortXRemuxInputProbeRequestCancel(VortXRemuxInputProbe *probe) {
    if (probe != NULL) atomic_store_explicit(&probe->cancelled, 1, memory_order_release);
}

bool VortXRemuxInputProbeIsCancelled(const VortXRemuxInputProbe *probe) {
    return probe != NULL && atomic_load_explicit(&probe->cancelled, memory_order_acquire) != 0;
}

void VortXRemuxInputProbeSetOpenInFlight(VortXRemuxInputProbe *probe, bool value) {
    if (probe != NULL) atomic_store_explicit(&probe->open_in_flight, value ? 1 : 0, memory_order_release);
}

void VortXRemuxInputProbeSetOpened(VortXRemuxInputProbe *probe) {
    if (probe != NULL) atomic_store_explicit(&probe->opened, 1, memory_order_release);
}

void VortXRemuxInputProbeSetStreamInfoDone(VortXRemuxInputProbe *probe) {
    if (probe != NULL) atomic_store_explicit(&probe->stream_info_done, 1, memory_order_release);
}

void VortXRemuxInputProbeObserveInputBytes(VortXRemuxInputProbe *probe, int64_t bytes_read) {
    if (probe == NULL || bytes_read <= 0) return;
    long long observed = atomic_load_explicit(&probe->input_bytes_read, memory_order_relaxed);
    while (bytes_read > observed && !atomic_compare_exchange_weak_explicit(
               &probe->input_bytes_read, &observed, bytes_read,
               memory_order_release, memory_order_relaxed)) {
    }
}

void VortXRemuxInputProbeSnapshotRead(const VortXRemuxInputProbe *probe,
                                      VortXRemuxInputProbeSnapshot *snapshot) {
    if (snapshot == NULL) return;
    if (probe == NULL) {
        *snapshot = (VortXRemuxInputProbeSnapshot){0};
        return;
    }
    snapshot->input_bytes_read = atomic_load_explicit(&probe->input_bytes_read, memory_order_acquire);
    snapshot->open_in_flight = atomic_load_explicit(&probe->open_in_flight, memory_order_acquire);
    snapshot->opened = atomic_load_explicit(&probe->opened, memory_order_acquire);
    snapshot->stream_info_done = atomic_load_explicit(&probe->stream_info_done, memory_order_acquire);
}

void VortXRemuxInputProbeSetInputContext(VortXRemuxInputProbe *probe, void *input_context) {
    if (probe != NULL) probe->input_context = input_context;
}

void *VortXRemuxInputProbeInputContext(const VortXRemuxInputProbe *probe) {
    return probe == NULL ? NULL : probe->input_context;
}
