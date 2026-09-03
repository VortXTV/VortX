#ifndef VORTX_REMUX_INPUT_PROBE_H
#define VORTX_REMUX_INPUT_PROBE_H

#include <stdbool.h>
#include <stdint.h>

/*
 * Narrow C11-atomic boundary for the remux input watchdog.
 *
 * The FFmpeg interrupt callback runs on the remux producer thread while cancellation and
 * MountProgress polling may run on other threads. Every field that crosses that boundary
 * is atomic and lock-free on the supported Apple 64-bit targets. The input context itself
 * is deliberately not atomic: only the producer thread and its synchronous FFmpeg callback
 * access it, and it is cleared before FFmpeg frees the context.
 */
typedef struct VortXRemuxInputProbe VortXRemuxInputProbe;

typedef struct {
    int64_t input_bytes_read;
    int32_t open_in_flight;
    int32_t opened;
    int32_t stream_info_done;
} VortXRemuxInputProbeSnapshot;

VortXRemuxInputProbe *VortXRemuxInputProbeCreate(void);
void VortXRemuxInputProbeDestroy(VortXRemuxInputProbe *probe);

/* Release store / acquire load: cancellation is the only interrupt control input. */
void VortXRemuxInputProbeRequestCancel(VortXRemuxInputProbe *probe);
bool VortXRemuxInputProbeIsCancelled(const VortXRemuxInputProbe *probe);

/* Producer stores release; watchdog snapshot reads acquire. Latching flags are monotonic. */
void VortXRemuxInputProbeSetOpenInFlight(VortXRemuxInputProbe *probe, bool value);
void VortXRemuxInputProbeSetOpened(VortXRemuxInputProbe *probe);
void VortXRemuxInputProbeSetStreamInfoDone(VortXRemuxInputProbe *probe);

/* Monotonic atomic max, called by the producer-thread FFmpeg callback. */
void VortXRemuxInputProbeObserveInputBytes(VortXRemuxInputProbe *probe, int64_t bytes_read);
void VortXRemuxInputProbeSnapshotRead(const VortXRemuxInputProbe *probe,
                                      VortXRemuxInputProbeSnapshot *snapshot);

/* Producer-thread-only AVFormatContext ownership. Never read by the UI/watchdog. */
void VortXRemuxInputProbeSetInputContext(VortXRemuxInputProbe *probe, void *input_context);
void *VortXRemuxInputProbeInputContext(const VortXRemuxInputProbe *probe);

#endif
