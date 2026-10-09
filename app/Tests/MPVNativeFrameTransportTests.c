/* Inert tests of methods mechanically extracted from the native patch.
 * No AVFoundation, decode, sockets, audio, GPU, or provider work. */
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "vortx_apple_frame.h"

static int checks;
#define CHECK(value, name) do { if (!(value)) { \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, name); return 1; \
} printf("PASS %s\n", name); checks++; } while (0)

struct buffer { int references, retains, releases; };
static void retain_buffer(void *p)
{
    struct buffer *b = p;
    b->references++;
    b->retains++;
}
static void release_buffer(void *p)
{
    struct buffer *b = p;
    assert(b->references > 0);
    b->references--;
    b->releases++;
}
static struct vortx_frame_buffer native_buffer(struct buffer *b)
{
    return (struct vortx_frame_buffer){b, retain_buffer, release_buffer};
}
struct receiver {
    int callbacks, destroys;
    struct mpv_vortx_apple_frame frames[8];
    bool detach_in_callback;
};
static void receive(void *context, mpv_vortx_apple_frame_session *s,
                    const struct mpv_vortx_apple_frame *frame)
{
    struct receiver *r = context;
    assert(r->callbacks < 8);
    r->frames[r->callbacks++] = *frame;
    /* These operations take the transport lock. This also proves callback
     * invocation is not under that lock. */
    if (r->detach_in_callback) {
        mpv_vortx_apple_frame_detach(s, frame->subscription);
        assert(!mpv_vortx_apple_frame_is_current(s, frame->lease));
        assert(r->destroys == 0); // callback still owns immutable receiver
    }
}
static void destroy_receiver(void *context)
{
    ((struct receiver *)context)->destroys++;
}
static bool publish(mpv_vortx_apple_frame_session *s, struct vortx_frame_stamp stamp,
                    uint64_t id, struct buffer *b)
{
    return vortx_frame_publish(s, stamp, id, native_buffer(b), 123.25, 0.04, 1.25,
                              9000000000, 8995000000, false);
}

struct blocked_receiver {
    pthread_mutex_t lock;
    pthread_cond_t condition;
    bool entered, resume;
    int destroys;
    uint64_t lease;
};
static void receive_blocked(void *context, mpv_vortx_apple_frame_session *s,
                            const struct mpv_vortx_apple_frame *frame)
{
    (void)s;
    struct blocked_receiver *r = context;
    pthread_mutex_lock(&r->lock);
    r->lease = frame->lease;
    r->entered = true;
    pthread_cond_broadcast(&r->condition);
    while (!r->resume)
        pthread_cond_wait(&r->condition, &r->lock);
    pthread_mutex_unlock(&r->lock);
}
static void destroy_blocked(void *context)
{
    struct blocked_receiver *r = context;
    pthread_mutex_lock(&r->lock);
    r->destroys++;
    pthread_mutex_unlock(&r->lock);
}
struct publish_job {
    mpv_vortx_apple_frame_session *session;
    struct vortx_frame_stamp stamp;
    struct buffer *buffer;
};
static void *publish_worker(void *context)
{
    struct publish_job *job = context;
    assert(publish(job->session, job->stamp, 400, job->buffer));
    return NULL;
}

struct gate_job { struct vortx_gpu_gate *gate; bool result; };
static void *close_gate_worker(void *context)
{
    struct gate_job *job = context;
    struct timespec deadline;
    timespec_get(&deadline, TIME_UTC);
    deadline.tv_sec += 2;
    job->result = vortx_gpu_gate_close(job->gate, &deadline);
    return NULL;
}
static void wait_until_gate_closed(struct vortx_gpu_gate *gate)
{
    struct timespec deadline;
    timespec_get(&deadline, TIME_UTC);
    deadline.tv_sec += 2;
    pthread_mutex_lock(&gate->lock);
    while (!gate->closed)
        assert(!pthread_cond_timedwait(&gate->idle, &gate->lock, &deadline));
    pthread_mutex_unlock(&gate->lock);
}

int main(void)
{
    mpv_vortx_apple_frame_session *s = vortx_frame_create();
    struct receiver a = {0}, b = {0}, c = {.detach_in_callback = true};
    struct buffer image = {0};
    CHECK(s && !vortx_frame_subscribe(s, 1, receive, destroy_receiver, &a),
          "no subscription before native source loaded");
    CHECK(vortx_frame_gpu_allowed(s), "ordinary foreground initialization remains allowed");
    vortx_frame_set_foreground(s, false);
    vortx_frame_source(s, false);
    vortx_frame_source(s, true);
    vortx_frame_reset(s, 0);
    CHECK(!vortx_frame_gpu_allowed(s),
          "new source and seek epochs cannot reopen session background authority");
    vortx_frame_set_foreground(s, true);
    CHECK(vortx_frame_gpu_allowed(s), "explicit foreground authority can reopen session");
    vortx_frame_source(s, true);
    uint64_t cookie = vortx_frame_subscribe(s, 1, receive, destroy_receiver, &a);
    struct vortx_frame_stamp first = vortx_frame_stamp(s);
    CHECK(cookie && publish(s, first, 1, &image) && publish(s, first, 2, &image),
          "two scheduled native frames retain exactly two leases");
    CHECK(image.references == 2 && !publish(s, first, 3, &image) && image.retains == 2,
          "third retained frame denied without retain or queue growth");
    CHECK(a.frames[0].media_pts == 123.25 && a.frames[0].media_duration == 0.04 &&
          a.frames[0].media_rate == 1.25 &&
          a.frames[0].host_deadline_ns == 9000000000 &&
          a.frames[0].host_observed_ns == 8995000000,
          "source PTS and raw host correlation are distinct and unchanged");
    mpv_vortx_apple_frame_release_frame(s, a.frames[0].lease);
    mpv_vortx_apple_frame_release_frame(s, a.frames[0].lease);
    CHECK(image.references == 1 && image.releases == 1 && publish(s, first, 3, &image),
          "duplicate stale release cannot free a reused slot");
    CHECK(!publish(s, first, 3, &image), "repeat frame identity is not enqueued twice");
    uint64_t b_cookie = vortx_frame_subscribe(s, 2, receive, destroy_receiver, &b);
    mpv_vortx_apple_frame_detach(s, cookie);
    CHECK(a.destroys == 1 && vortx_frame_owner_current(s, b_cookie) &&
          !mpv_vortx_apple_frame_is_current(s, a.frames[1].lease),
          "old detach and old frames cannot retire or enter successor receiver");
    mpv_vortx_apple_frame_release_frame(s, a.frames[1].lease);
    mpv_vortx_apple_frame_release_frame(s, a.frames[2].lease);
    vortx_frame_reset(s, 50);
    struct vortx_frame_stamp second = vortx_frame_stamp(s);
    CHECK(!publish(s, first, 99, &image) && !publish(s, second, 50, &image),
          "reset rejects old epoch and retained old redraw despite relabeling");
    CHECK(publish(s, second, 51, &image) &&
          mpv_vortx_apple_frame_is_current(s, b.frames[0].lease),
          "newly scheduled post-reset frame is admitted");
    vortx_frame_source(s, false);
    vortx_frame_source(s, true);
    uint64_t c_cookie = vortx_frame_subscribe(s, 1, receive, destroy_receiver, &c);
    CHECK(c_cookie && !publish(s, second, 100, &image) && b.destroys == 1 &&
          !mpv_vortx_apple_frame_is_current(s, b.frames[0].lease),
          "source A to B to A cannot launder prior native epoch");
    mpv_vortx_apple_frame_release_frame(s, b.frames[0].lease);
    CHECK(publish(s, vortx_frame_stamp(s), 1, &image) && c.destroys == 1,
          "reentrant detach invalidates frame without callback-under-lock deadlock");
    mpv_vortx_apple_frame_release_frame(s, c.frames[0].lease);
    CHECK(image.references == 0 && image.retains == image.releases,
          "all retained pixels released exactly once");

    struct receiver d = {0};
    vortx_frame_subscribe(s, 3, receive, destroy_receiver, &d);
    struct vortx_frame_stamp stamp = vortx_frame_stamp(s);
    CHECK(!vortx_frame_publish(s, stamp, 2, native_buffer(&image), NAN, 0.04, 1, 1, 1, false) &&
          !vortx_frame_publish(s, stamp, 2, native_buffer(&image), 5, 0.04, 1, 0, 1, false),
          "invalid media clock or missing running deadline refused");
    CHECK(!vortx_frame_publish(s, stamp, 2, native_buffer(&image), 5, 0.04, -1, 1, 1, false) &&
          !vortx_frame_publish(s, stamp, 2, native_buffer(&image), 5, 0.04, NAN, 1, 1, false) &&
          !vortx_frame_publish(s, stamp, 2, native_buffer(&image), 5, 0.04, 0, 1, 1, true),
          "reverse invalid and zero scheduled rates cannot pretend forward timing");
    CHECK(vortx_frame_publish(s, stamp, 2, native_buffer(&image), 5, 0.04, 1, 0, 1, true) &&
          d.frames[0].paused && d.frames[0].host_deadline_ns == 0,
          "paused redraw remains paused and invents no host deadline");
    mpv_vortx_apple_frame_release_frame(s, d.frames[0].lease);

    struct blocked_receiver blocked = {
        .lock = PTHREAD_MUTEX_INITIALIZER, .condition = PTHREAD_COND_INITIALIZER,
    };
    uint64_t blocked_cookie = vortx_frame_subscribe(s, 4, receive_blocked,
                                                  destroy_blocked, &blocked);
    struct publish_job job = {s, vortx_frame_stamp(s), &image};
    pthread_t worker;
    assert(!pthread_create(&worker, NULL, publish_worker, &job));
    pthread_mutex_lock(&blocked.lock);
    while (!blocked.entered)
        pthread_cond_wait(&blocked.condition, &blocked.lock);
    pthread_mutex_unlock(&blocked.lock);
    mpv_vortx_apple_frame_detach(s, blocked_cookie);
    CHECK(blocked.destroys == 0 && !mpv_vortx_apple_frame_is_current(s, blocked.lease),
          "concurrent detach invalidates but cannot destroy in-flight receiver");
    pthread_mutex_lock(&blocked.lock);
    blocked.resume = true;
    pthread_cond_broadcast(&blocked.condition);
    pthread_mutex_unlock(&blocked.lock);
    pthread_join(worker, NULL);
    CHECK(blocked.destroys == 1, "receiver destroyed after final callback returns");
    mpv_vortx_apple_frame_release_frame(s, blocked.lease);
    pthread_cond_destroy(&blocked.condition);
    pthread_mutex_destroy(&blocked.lock);

    struct receiver e = {0};
    vortx_frame_subscribe(s, 5, receive, destroy_receiver, &e);
    CHECK(publish(s, vortx_frame_stamp(s), 401, &image), "preterminal frame admitted");
    vortx_frame_close(s);
    vortx_frame_set_foreground(s, true);
    vortx_frame_report(s, MPV_VORTX_FRAME_READY);
    CHECK(!vortx_frame_gpu_allowed(s) &&
          mpv_vortx_apple_frame_reason(s) == MPV_VORTX_FRAME_CLOSED,
          "late foreground and success report cannot resurrect terminal session");
    CHECK(!mpv_vortx_apple_frame_is_current(s, e.frames[0].lease) && e.destroys == 1 &&
          !vortx_frame_subscribe(s, 6, receive, destroy_receiver, &a),
          "terminal close invalidates all ownership and rejects resurrection");
    mpv_vortx_apple_frame_release_frame(s, e.frames[0].lease);
    mpv_vortx_apple_frame_release(s);
    CHECK(image.references == 0, "late frame release balances after native terminal close");

    uint64_t deadline;
    CHECK(vortx_frame_host_deadline(9000, 1000, 1100, false, &deadline) &&
          deadline == 9100, "scheduled future deadline maps once through exact process offset");
    CHECK(vortx_frame_host_deadline(9000, 1000, 900, false, &deadline) &&
          deadline == 8900, "past scheduled deadline does not invent media rewind");
    CHECK(vortx_frame_host_deadline(9000, 1000, 0, true, &deadline) && !deadline,
          "paused deadline remains absent while raw observation is valid");
    CHECK(!vortx_frame_host_deadline(9000, 1000, 0, false, &deadline) &&
          !vortx_frame_host_deadline(9000, 10000, 100, false, &deadline) &&
          !vortx_frame_host_deadline(9000, -1, 100, false, &deadline) &&
          !vortx_frame_host_deadline(UINT64_MAX, 0, 1, false, &deadline),
          "invalid clock domains and overflow fail closed without unsigned wrap");

    struct vortx_gpu_gate gate;
    vortx_gpu_gate_init(&gate);
    CHECK(vortx_gpu_gate_enter(&gate), "foreground decoder allocation admitted");
    struct timespec expired = {0};
    CHECK(!vortx_gpu_gate_close(&gate, &expired) && !vortx_gpu_gate_enter(&gate),
          "in-flight allocation prevents drain receipt and closes new admission");
    vortx_gpu_gate_leave(&gate);
    CHECK(vortx_gpu_gate_close(&gate, &expired), "zero in-flight is an actual drain receipt");
    vortx_gpu_gate_reopen(&gate);
    CHECK(vortx_gpu_gate_enter(&gate), "explicit foreground restoration reopens allocation");
    struct gate_job gate_job = {&gate, false};
    assert(!pthread_create(&worker, NULL, close_gate_worker, &gate_job));
    wait_until_gate_closed(&gate);
    CHECK(!vortx_gpu_gate_enter(&gate), "waiting close prevents concurrent new allocation");
    vortx_gpu_gate_leave(&gate);
    pthread_join(worker, NULL);
    CHECK(gate_job.result, "concurrent allocation exit releases real waiting drain");
    vortx_gpu_gate_reopen(&gate);
    assert(vortx_gpu_gate_enter(&gate));
    gate_job.result = true;
    assert(!pthread_create(&worker, NULL, close_gate_worker, &gate_job));
    wait_until_gate_closed(&gate);
    vortx_gpu_gate_reopen(&gate);
    vortx_gpu_gate_leave(&gate);
    pthread_join(worker, NULL);
    CHECK(!gate_job.result, "foreground reopening revokes late close acknowledgement");
    vortx_gpu_gate_destroy(&gate);
    printf("RESULT %d PASS (actual transport methods; not VO/AVKit/device acceptance)\n", checks);
    return 0;
}
