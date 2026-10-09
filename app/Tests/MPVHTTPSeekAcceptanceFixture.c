// Real libmpv transport/packet acceptance; synthetic loopback media, null outputs.
#include <mpv/client.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double number(mpv_handle *m, const char *name)
{
    double n;
    return mpv_get_property(m, name, MPV_FORMAT_DOUBLE, &n) >= 0 ? n : NAN;
}
static int flag(mpv_handle *m, const char *name)
{
    int n;
    return mpv_get_property(m, name, MPV_FORMAT_FLAG, &n) >= 0 ? n : -1;
}
static int64_t seek_count(mpv_handle *m, double *cached_end)
{
    mpv_node node = {0};
    int64_t count = -1;
    *cached_end = -1;
    if (mpv_get_property(m, "demuxer-cache-state", MPV_FORMAT_NODE, &node) < 0)
        return -1;
    if (node.format == MPV_FORMAT_NODE_MAP && node.u.list) {
        for (int i = 0; i < node.u.list->num; ++i) {
            mpv_node *value = &node.u.list->values[i];
            const char *key = node.u.list->keys[i];
            if (!strcmp(key, "debug-low-level-seeks") && value->format == MPV_FORMAT_INT64)
                count = value->u.int64;
            if (!strcmp(key, "seekable-ranges") && value->format == MPV_FORMAT_NODE_ARRAY && value->u.list) {
                for (int j = 0; j < value->u.list->num; ++j) {
                    mpv_node *range = &value->u.list->values[j];
                    if (range->format != MPV_FORMAT_NODE_MAP || !range->u.list) continue;
                    double start = NAN, end = NAN;
                    for (int k = 0; k < range->u.list->num; ++k) {
                        mpv_node *n = &range->u.list->values[k];
                        if (n->format != MPV_FORMAT_DOUBLE) continue;
                        if (!strcmp(range->u.list->keys[k], "start")) start = n->u.double_;
                        if (!strcmp(range->u.list->keys[k], "end")) end = n->u.double_;
                    }
                    if (isfinite(start) && start <= 1 && isfinite(end) && end > *cached_end)
                        *cached_end = end;
                }
            }
        }
    }
    mpv_free_node_contents(&node);
    return count;
}
static int handshake(const char *expected)
{
    char line[32];
    return fgets(line, sizeof(line), stdin) && !strcmp(line, expected);
}
static int issue_seek(mpv_handle *m, double target, int sequence)
{
    char argument[40];
    snprintf(argument, sizeof(argument), "%.3f", target);
    const char *command[] = {"seek", argument, "absolute", NULL};
    int status = mpv_command(m, command);
    printf("COMMAND sequence=%d target=%.3f status=%d monotonic=%.6f\n", sequence, target, status, now());
    fflush(stdout);
    return status;
}
int main(int argc, char **argv)
{
    if (argc != 5 || strncmp(argv[1], "http://127.0.0.1:", 17)) return 64;
    const char *end = argv[1] + 17;
    if (*end < '0' || *end > '9') return 64;
    while (*end >= '0' && *end <= '9') ++end;
    if (strcmp(end, "/synthetic.mkv")) return 64;
    const char *mode = argv[2];
    int playing = !strcmp(mode, "playing"), rapid = !strcmp(mode, "rapid");
    int cached = !strcmp(mode, "cached"), stop = !strcmp(mode, "stop");
    int replace = !strcmp(mode, "replace");
    if (!playing && !rapid && !cached && !stop && !replace &&
        strcmp(mode, "immediate") && strcmp(mode, "stalled")) return 64;
    mpv_handle *m = mpv_create();
    if (!m) return 65;
    int result = 1;
    const char *options[][2] = {{"config", "no"}, {"terminal", "no"}, {"vo", "null"}, {"ao", "null"},
        {"load-scripts", "no"}, {"cache", "yes"}, {"demuxer-readahead-secs", "300"},
        {"demuxer-max-bytes", "512MiB"}, {"network-timeout", argv[3]}, {"stream-lavf-o", argv[4]}};
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i)
        if (mpv_set_option_string(m, options[i][0], options[i][1]) < 0) goto cleanup;
    if (mpv_initialize(m) < 0) goto cleanup;
    char *version = mpv_get_property_string(m, "mpv-version");
    printf("RUNTIME version=%s mode=%s nullOutputs=1\n", version ? version : "unavailable", mode);
    mpv_free(version);
    const char *load[] = {"loadfile", argv[1], "replace", NULL};
    if (mpv_command(m, load) < 0) goto cleanup;
    double begin = now(), command_time = 0, target = cached ? 10.125 : rapid ? 120.5 : 104.146;
    double last = 0;
    int64_t initial_count = -1;
    int saw_seek = 0, saw_loaded = 0;
    while (now() - begin < 18) {
        mpv_event *event = mpv_wait_event(m, 0.02);
        double pos = number(m, "time-pos"), cached_end;
        int64_t count = seek_count(m, &cached_end);
        if (!command_time && pos >= 0.4 && flag(m, "seeking") == 0 && (!cached || cached_end > 20)) {
            if (!playing && mpv_set_property_string(m, "pause", "yes") < 0) goto cleanup;
            printf("READY pos=%.3f cachedEnd=%.3f pause=%d counter=%lld\n", pos, cached_end,
                   flag(m, "pause"), (long long)count);
            fflush(stdout);
            if (!handshake("go\n")) goto cleanup;
            while (mpv_wait_event(m, 0)->event_id != MPV_EVENT_NONE) {}
            initial_count = seek_count(m, &cached_end);
            if (initial_count < 0) goto cleanup;
            command_time = now();
            if (stop || replace) {
                if (issue_seek(m, 104.146, 1) < 0) goto cleanup;
                printf("FIRST_SEEK\n"); fflush(stdout);
                if (!handshake("latest\n")) goto cleanup;
                command_time = now();
            }
            if (stop) {
                const char *command[] = {"stop", NULL};
                if (mpv_command(m, command) < 0) goto cleanup;
                printf("STOP_ACCEPTED\n");
            } else if (replace) {
                char replacement[256];
                const char suffix[] = "/replacement.mkv";
                size_t prefix = (size_t)(end - argv[1]);
                if (prefix > sizeof(replacement) - sizeof(suffix)) goto cleanup;
                memcpy(replacement, argv[1], prefix);
                memcpy(replacement + prefix, suffix, sizeof(suffix));
                const char *command[] = {"loadfile", replacement, "replace", NULL};
                if (mpv_command(m, command) < 0) goto cleanup;
                printf("REPLACEMENT_ACCEPTED\n");
            } else if (rapid) {
                if (issue_seek(m, 104.146, 1) < 0) goto cleanup;
                printf("FIRST_SEEK\n"); fflush(stdout);
                if (!handshake("latest\n")) goto cleanup;
                if (issue_seek(m, 60.125, 2) < 0 || issue_seek(m, target, 3) < 0) goto cleanup;
                command_time = now();
            } else if (issue_seek(m, target, 1) < 0) {
                goto cleanup;
            }
            fflush(stdout);
            continue;
        }
        if (!command_time) continue;
        double elapsed = now() - command_time;
        if (event->event_id == MPV_EVENT_SEEK) saw_seek = 1;
        if (event->event_id == MPV_EVENT_FILE_LOADED) saw_loaded = 1;
        if (event->event_id == MPV_EVENT_SEEK || event->event_id == MPV_EVENT_PLAYBACK_RESTART ||
            event->event_id == MPV_EVENT_END_FILE || elapsed - last >= 1) {
            printf("NATIVE elapsed=%.3f event=%s pos=%.3f target=%.3f counter=%lld initial=%lld seeking=%d eof=%d pause=%d\n",
                   elapsed, mpv_event_name(event->event_id), pos, target, (long long)count,
                   (long long)initial_count, flag(m, "seeking"), flag(m, "eof-reached"), flag(m, "pause"));
            fflush(stdout);
            last = elapsed;
        }
        if (stop && flag(m, "idle-active") == 1) {
            printf("STOPPED elapsed=%.3f idle=1\n", elapsed);
            result = 0;
            break;
        }
        if (replace && saw_loaded && event->event_id == MPV_EVENT_PLAYBACK_RESTART &&
            isfinite(pos) && pos >= 0 && pos < 1 && flag(m, "pause") == 1 && flag(m, "eof-reached") == 0) {
            char *path = mpv_get_property_string(m, "path");
            int owned = path && strstr(path, "/replacement.mkv") != NULL;
            mpv_free(path);
            if (owned) {
                printf("REPLACED elapsed=%.3f newPathOwned=1 pos=%.3f pause=1\n", elapsed, pos);
                result = 0;
                break;
            }
        }
        if (!stop && !replace && saw_seek && event->event_id == MPV_EVENT_PLAYBACK_RESTART &&
            isfinite(pos) && fabs(pos - target) <= 0.5 && flag(m, "seeking") == 0 &&
            flag(m, "eof-reached") == 0 && flag(m, "pause") == !playing &&
            (cached ? count == initial_count : count > initial_count)) {
            printf("LANDED elapsed=%.3f pos=%.3f target=%.3f counter=%lld pause=%d\n",
                   elapsed, pos, target, (long long)count, flag(m, "pause"));
            result = 0;
            break;
        }
        if (elapsed >= 6) {
            printf("NOT_SETTLED elapsed=%.3f counter=%lld initial=%lld\n", elapsed,
                   (long long)count, (long long)initial_count);
            result = 2;
            break;
        }
    }
cleanup:
    mpv_terminate_destroy(m);
    printf("DESTROY result=%d\n", result);
    return result;
}
