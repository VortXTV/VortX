/* Future real-native fixture CODE ONLY; not compiled/run in this session.
 * Link against the matched FF+MPV afterimages and a controlled real HTTP VOD.
 * No fake AVIO, layout casting, alternate peer registry, or model authority.
 * The harness supplies its actual consumer event pump and a real utility
 * dispatch+JOIN primitive. Never call this from the demux producer thread. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include "genuine_fixture.h"
#include "genuine_observation.h"
#include "demux/demux.h"
#include "stream/reference_source.h"

struct fixture_worker {
    struct demux_reference_request *request;
    bool decoded;
};
static void fixture_run(void *opaque)
{
    struct fixture_worker *worker = opaque;
    worker->decoded = demux_reference_reader_run(worker->request);
}

// pump_consumer returns only after handling at least one actual demux wakeup
// or finite timer; run_and_join MUST join before returning, even on cancel.
// Test source must have a sole selected text track, known original track start,
// original strong validator, direct verified transport, and a finite sample.
bool fixture_real_reader_roundtrip(
    struct demuxer *actual_demux, int actual_selected_index, int64_t deadline_ns,
    void (*pump_consumer)(void *), void *pump_opaque,
    void (*run_and_join)(void (*)(void *), void *),
    struct demux_reference_result *out)
{
    unsigned capture_wakes = genuine_foreign_demux_wakes(pump_opaque);
    struct demux_reference_request *request = demux_reference_reader_request(
        actual_demux, actual_selected_index, deadline_ns);
    if (!request)
        return false;
    struct stream_reference_lease old_output = {0};
    assert(demux_reference_request_take(request, &old_output) == DEMUX_REFERENCE_UNAVAILABLE);
    assert(!old_output.source); // old INITIAL_REQUEST_ONLY gate stays separate
    while (demux_reference_reader_status(request) == DEMUX_REFERENCE_READER_PENDING ||
           genuine_foreign_demux_wakes(pump_opaque) == capture_wakes)
        pump_consumer(pump_opaque);
    struct fixture_worker worker = {.request = request};
    if (demux_reference_reader_status(request) == DEMUX_REFERENCE_READER_CAPTURED)
        run_and_join(fixture_run, &worker);
    unsigned revalidate_wakes = genuine_foreign_demux_wakes(pump_opaque);
    bool ok = worker.decoded && demux_reference_reader_revalidate(actual_demux, request);
    while (ok && (demux_reference_reader_status(request) == DEMUX_REFERENCE_READER_REVALIDATING ||
                 genuine_foreign_demux_wakes(pump_opaque) == revalidate_wakes))
        pump_consumer(pump_opaque);
    ok = ok && demux_reference_reader_take(request, out);
    if (ok) {
        assert(out->complete && out->num_pairs && out->num_pairs <= 1024);
        assert(out->prefix_start_ms == 0 && out->prefix_end_ms == 1080000);
        assert(out->input_bytes <= 128u * 1024u * 1024u);
        struct demux_reference_result second = {0};
        assert(!demux_reference_reader_take(request, &second));
    }
    demux_reference_request_cancel(request);
    demux_reference_request_release(&request); // every launched worker joined
    assert(!request);
    return ok;
}

// The real consumer can run this after capture to verify a cached-seek/track-
// reset fence without touching the original URL or borrowing a source pointer.
// A real transition is required: demux_flush is an existing native operation.
bool fixture_real_owner_reset_rejects(struct demuxer *actual_demux,
                                     struct demux_reference_request *captured)
{
    demux_flush(actual_demux);
    struct demux_reference_result out = {0};
    return demux_reference_request_cancelled(captured) &&
        !demux_reference_reader_run(captured) &&
        !demux_reference_reader_revalidate(actual_demux, captured) &&
        !demux_reference_reader_take(captured, &out);
}
