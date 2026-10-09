// Raw AVIO only: synthetic bytes on literal loopback, no demuxer/decoder/device.
#include <libavformat/avio.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct owner {
    atomic_uint requested;
    atomic_bool stopped;
    unsigned active; // Accessed only by AVIO's owning thread/callback.
};
static int interrupted(void *opaque)
{
    struct owner *o = opaque;
    return atomic_load(&o->stopped) || atomic_load(&o->requested) != o->active;
}
static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static void *supersede(void *opaque)
{
    struct timespec delay = {.tv_nsec = 200000000};
    nanosleep(&delay, NULL);
    atomic_fetch_add(&((struct owner *)opaque)->requested, 1);
    return NULL;
}
static int reopen(AVIOContext **candidate, const char *url, AVDictionary *captured,
                  struct owner *owner, int64_t offset)
{
    AVDictionary *options = NULL;
    AVIOInterruptCB cb = {.callback = interrupted, .opaque = owner};
    int rc = av_dict_copy(&options, captured, 0);
    if (rc >= 0) rc = av_dict_set_int(&options, "offset", offset, 0);
    if (rc >= 0) rc = avio_open2(candidate, url, AVIO_FLAG_READ, &cb, &options);
    av_dict_free(&options);
    if (rc < 0) return rc;

    // The HTTP offset option positions the protocol, not the new AVIO buffer.
    // Align through the public seek API; direct prevents AVIO's short-read path.
    int direct = (*candidate)->direct;
    (*candidate)->direct = 1;
    int64_t position = avio_seek(*candidate, offset, SEEK_SET);
    (*candidate)->direct = direct;
    if (position != offset || avio_tell(*candidate) != offset || interrupted(owner)) {
        avio_closep(candidate);
        return AVERROR_EXIT;
    }
    return 0;
}
int main(int argc, char **argv)
{
    if (argc != 3 || strncmp(argv[1], "http://127.0.0.1:", 17)) return 64;
    const char *end = argv[1] + 17;
    if (*end < '0' || *end > '9') return 64;
    while (*end >= '0' && *end <= '9') ++end;
    if (strcmp(end, "/bytes")) return 64;
    const char *mode = argv[2];
    bool stop = !strcmp(mode, "stop"), rapid = !strcmp(mode, "supersede");
    bool bad = !strcmp(mode, "ignored") || !strcmp(mode, "invalid");
    if (!stop && !rapid && !bad && strcmp(mode, "recover")) return 64;
    av_log_set_level(AV_LOG_QUIET); // No URLs, headers or global FFmpeg trace.
    struct owner owner = {.requested = 0, .stopped = false, .active = 0};
    AVIOInterruptCB cb = {.callback = interrupted, .opaque = &owner};
    AVDictionary *options = NULL, *captured = NULL;
    AVIOContext *old = NULL, *candidate = NULL;
    unsigned char bytes[4096];
    int result = 1;
    av_dict_set(&options, "user_agent", "fixture-source-A", 0);
    av_dict_set(&options, "referer", "http://127.0.0.1/fixture-only", 0);
    av_dict_set(&options, "headers", "X-Fixture: comma,\"quoted\",\\slash\r\n", 0);
    av_dict_set(&options, "reconnect", "1", 0);
    av_dict_set(&options, "reconnect_streamed", "1", 0);
    av_dict_set(&options, "reconnect_delay_max", "7", 0);
    av_dict_set(&options, "multiple_requests", "1", 0);
    av_dict_set(&options, "timeout", "30000000", 0);
    if (av_dict_copy(&captured, options, 0) < 0) goto cleanup;
    if (avio_open2(&old, argv[1], AVIO_FLAG_READ, &cb, &options) < 0) goto cleanup;
    av_dict_free(&options);
    if (avio_read(old, bytes, sizeof(bytes)) != (int)sizeof(bytes)) goto cleanup;
    pthread_t thread;
    if (pthread_create(&thread, NULL, supersede, &owner)) goto cleanup;
    double started = now();
    int read_status = avio_read_partial(old, bytes, sizeof(bytes));
    pthread_join(thread, NULL);
    double elapsed = now() - started;
    printf("INTERRUPTED status=%d expected=%d elapsed=%.3f error=%d eof=%d\n",
           read_status, AVERROR_EXIT, elapsed, old->error, old->eof_reached);
    if (read_status != AVERROR_EXIT || old->error != AVERROR_EXIT || elapsed >= 2) goto cleanup;

    // Preserve this source's learned cookies before retiring its poisoned AVIO.
    uint8_t *cookies = NULL;
    if (av_opt_get(old, "cookies", AV_OPT_SEARCH_CHILDREN, &cookies) < 0) goto cleanup;
    printf("COOKIE_CAPTURE bytes=%zu containsSyntheticSeed=%d\n", cookies ? strlen((char *)cookies) : 0,
           cookies && strstr((char *)cookies, "seed=synthetic") != NULL);
    if (cookies && cookies[0] && av_dict_set(&captured, "cookies", (char *)cookies, 0) < 0) {
        av_free(cookies);
        goto cleanup;
    }
    av_free(cookies);
    avio_closep(&old);
    owner.active = atomic_load(&owner.requested);
    if (stop) atomic_store(&owner.stopped, true);
    // Later source options must not influence the frozen original source snapshot.
    av_dict_set(&options, "user_agent", "later-source-must-not-leak", 0);
    int64_t target = 131072;
    if (rapid && pthread_create(&thread, NULL, supersede, &owner)) goto cleanup;
    int status = reopen(&candidate, argv[1], captured, &owner, target);
    if (rapid) {
        pthread_join(thread, NULL);
        printf("SUPERSEDED status=%d admitted=%d\n", status, candidate != NULL);
        if (status != AVERROR_EXIT || candidate) goto cleanup;
        owner.active = atomic_load(&owner.requested);
        target = 196608;
        status = reopen(&candidate, argv[1], captured, &owner, target);
    }
    if (stop || bad) {
        printf("REJECTED status=%d admitted=%d stopped=%d\n", status, candidate != NULL, stop);
        result = status < 0 && !candidate ? 0 : 1;
        goto cleanup;
    }
    if (status < 0 || !candidate || candidate->error || candidate->eof_reached) goto cleanup;
    if (avio_read(candidate, bytes, sizeof(bytes)) != (int)sizeof(bytes)) goto cleanup;
    for (size_t i = 0; i < sizeof(bytes); ++i)
        if (bytes[i] != (target + (int64_t)i) % 251) goto cleanup;
    printf("RECOVERED offset=%lld tell=%lld epoch=%u exactBytes=1 cleanError=%d\n",
           (long long)target, (long long)avio_tell(candidate), owner.active, candidate->error == 0);
    result = avio_tell(candidate) == target + (int64_t)sizeof(bytes) ? 0 : 1;
cleanup:
    avio_closep(&candidate);
    avio_closep(&old);
    av_dict_free(&captured);
    av_dict_free(&options);
    printf("CLEANUP result=%d\n", result);
    return result;
}
