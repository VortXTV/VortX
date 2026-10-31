/* Whole canonical TCP TU, observer-only delegation of the unchanged real wait.
 * Actual second callback proves the real network helper already completed one
 * poll with EAGAIN while the genuine admitted HTTP BODY read is outstanding. */
#include <stdbool.h>
#include <libavformat/avio.h>
#include "libavformat/network.h"
#include "genuine_observation.h"
#ifndef GENUINE_TCP_SOURCE
#error "Root must bind GENUINE_TCP_SOURCE to the accepted canonical TCP successor"
#endif
static int genuine_wait_delegate(int fd, int write, int64_t timeout,
                                 AVIOInterruptCB *interrupt);
/* network.h was included before this macro, so the original helper declaration
 * and implementation are not renamed. Only actual TCP callsites delegate. */
#define ff_network_wait_fd_timeout genuine_wait_delegate
#include GENUINE_TCP_SOURCE
#undef ff_network_wait_fd_timeout

struct observed_wait { AVIOInterruptCB *original; unsigned callbacks; bool signalled; };
static int observe_interrupt(void *opaque)
{
    struct observed_wait *state = opaque;
    int result = ff_check_interrupt(state->original);
    state->callbacks++;
    if (!result && state->callbacks >= 2 && !state->signalled) {
        state->signalled = true;
        genuine_body_wait_observed();
    }
    return result;
}
static int genuine_wait_delegate(int fd, int write, int64_t timeout,
                                 AVIOInterruptCB *interrupt)
{
    if (write || !genuine_body_phase_active())
        return ff_network_wait_fd_timeout(fd, write, timeout, interrupt);
    struct observed_wait state = {.original = interrupt};
    AVIOInterruptCB observed = {.callback = observe_interrupt, .opaque = &state};
    return ff_network_wait_fd_timeout(fd, write, timeout, &observed);
}
