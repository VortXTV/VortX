// Native concurrency regression for the C11 remux input probe.
//
// Run:
//   xcrun clang -std=c11 -Wall -Wextra -Werror -pthread \
//     -Iapp/Sources/Player app/Sources/Player/VortXRemuxInputProbe.c \
//     app/Tests/VortXRemuxInputProbeConcurrencyTests.c \
//     -o /tmp/vortx-remux-input-probe-concurrency && /tmp/vortx-remux-input-probe-concurrency
//
// On hosts with a working ThreadSanitizer runtime, add `-fsanitize=thread` to the same command.

#include "VortXRemuxInputProbe.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { iterations = 500000 };

typedef struct {
    VortXRemuxInputProbe *probe;
    atomic_int failed;
} Fixture;

static void fail(Fixture *fixture, const char *message) {
    if (atomic_exchange(&fixture->failed, 1) == 0) fprintf(stderr, "FAIL  %s\n", message);
}

static void *producer(void *opaque) {
    Fixture *fixture = opaque;
    VortXRemuxInputProbeSetOpenInFlight(fixture->probe, true);
    for (int64_t i = 1; i <= iterations; ++i) {
        VortXRemuxInputProbeObserveInputBytes(fixture->probe, i);
    }
    VortXRemuxInputProbeSetOpened(fixture->probe);
    VortXRemuxInputProbeSetStreamInfoDone(fixture->probe);
    VortXRemuxInputProbeSetOpenInFlight(fixture->probe, false);
    return NULL;
}

static void *watchdog(void *opaque) {
    Fixture *fixture = opaque;
    int64_t previous_bytes = 0;
    int opened_seen = 0;
    int stream_info_seen = 0;
    while (!VortXRemuxInputProbeIsCancelled(fixture->probe)) {
        VortXRemuxInputProbeSnapshot snapshot;
        VortXRemuxInputProbeSnapshotRead(fixture->probe, &snapshot);
        if (snapshot.input_bytes_read < previous_bytes) {
            fail(fixture, "input byte receipt regressed");
            return NULL;
        }
        previous_bytes = snapshot.input_bytes_read;
        if (opened_seen && snapshot.opened == 0) {
            fail(fixture, "opened receipt regressed");
            return NULL;
        }
        if (stream_info_seen && snapshot.stream_info_done == 0) {
            fail(fixture, "stream-info receipt regressed");
            return NULL;
        }
        opened_seen |= snapshot.opened != 0;
        stream_info_seen |= snapshot.stream_info_done != 0;
    }
    return NULL;
}

/* Mirrors FFmpeg's interrupt callback: it must observe an arbitrary-thread cancellation promptly. */
static void *interrupt_callback(void *opaque) {
    Fixture *fixture = opaque;
    while (!VortXRemuxInputProbeIsCancelled(fixture->probe)) {
    }
    return NULL;
}

int main(void) {
    Fixture fixture = { .probe = VortXRemuxInputProbeCreate() };
    if (fixture.probe == NULL) {
        fprintf(stderr, "FAIL  probe allocation\n");
        return EXIT_FAILURE;
    }
    atomic_init(&fixture.failed, 0);

    pthread_t producer_thread;
    pthread_t watchdog_thread;
    pthread_t interrupt_thread;
    if (pthread_create(&producer_thread, NULL, producer, &fixture) != 0
        || pthread_create(&watchdog_thread, NULL, watchdog, &fixture) != 0
        || pthread_create(&interrupt_thread, NULL, interrupt_callback, &fixture) != 0) {
        fprintf(stderr, "FAIL  pthread_create\n");
        VortXRemuxInputProbeDestroy(fixture.probe);
        return EXIT_FAILURE;
    }
    pthread_join(producer_thread, NULL);
    VortXRemuxInputProbeRequestCancel(fixture.probe);
    pthread_join(watchdog_thread, NULL);
    pthread_join(interrupt_thread, NULL);

    VortXRemuxInputProbeSnapshot snapshot;
    VortXRemuxInputProbeSnapshotRead(fixture.probe, &snapshot);
    if (snapshot.input_bytes_read != iterations || snapshot.open_in_flight != 0
        || snapshot.opened == 0 || snapshot.stream_info_done == 0
        || !VortXRemuxInputProbeIsCancelled(fixture.probe)) {
        fail(&fixture, "terminal receipt mismatch");
    }
    VortXRemuxInputProbeDestroy(fixture.probe);
    if (atomic_load(&fixture.failed) != 0) return EXIT_FAILURE;
    puts("PASS  remux input probe concurrent cancellation and progress receipts");
    return EXIT_SUCCESS;
}
