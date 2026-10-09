// Literal-loopback transport diagnostic, not an installed player/device test. No audible/visible output.
#include <mpv/client.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double number(mpv_handle *m, const char *property) {
    double value;
    return mpv_get_property(m, property, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : NAN;
}
static int flag(mpv_handle *m, const char *property) {
    int value;
    return mpv_get_property(m, property, MPV_FORMAT_FLAG, &value) >= 0 ? value : -1;
}
static int64_t counter(mpv_handle *m, int *status) {
    mpv_node node = {0};
    *status = mpv_get_property(m, "demuxer-cache-state", MPV_FORMAT_NODE, &node);
    if (*status < 0) return -1;
    int64_t result = -1;
    if (node.format == MPV_FORMAT_NODE_MAP && node.u.list) {
        for (int i = 0; i < node.u.list->num; ++i) {
            mpv_node *value = &node.u.list->values[i];
            if (!strcmp(node.u.list->keys[i], "debug-low-level-seeks") &&
                value->format == MPV_FORMAT_INT64 && value->u.int64 >= 0) result = value->u.int64;
        }
    }
    mpv_free_node_contents(&node);
    return result;
}
static void state(mpv_handle *m, double elapsed, const char *event) {
    int status;
    int64_t count = counter(m, &status);
    printf("NATIVE elapsed=%.3f event=%s pos=%.3f seeking=%d eof=%d pause=%d counterValid=%d counter=%lld counterRead=%d streamPos=%.0f\n",
           elapsed, event, number(m, "time-pos"), flag(m, "seeking"), flag(m, "eof-reached"),
           flag(m, "pause"), count >= 0, (long long)count, status, number(m, "stream-pos"));
    fflush(stdout);
}
int main(int argc, char **argv) {
    if (argc != 5 || strncmp(argv[1], "http://127.0.0.1:", 17)) return 64;
    const char *port = argv[1] + 17;
    while (*port >= '0' && *port <= '9') ++port;
    if (strcmp(port, "/synthetic.mkv") && strcmp(port, "/redirect")) return 64;
    int permit_deadline = !strcmp(argv[4], "negative-control");
    mpv_handle *m = mpv_create();
    if (!m) return 65;
    const char *options[][2] = {{"config", "no"}, {"terminal", "no"}, {"vo", "null"}, {"ao", "null"},
        {"load-scripts", "no"}, {"cache", "yes"}, {"demuxer-readahead-secs", "300"}, {"demuxer-max-bytes", "512MiB"},
        {"network-timeout", argv[2]}, {"stream-lavf-o", argv[3]}};
    for (unsigned i = 0; i < sizeof(options) / sizeof(options[0]); ++i)
        if (mpv_set_option_string(m, options[i][0], options[i][1]) < 0) return 66;
    if (mpv_initialize(m) < 0) return 67;
    char *version = mpv_get_property_string(m, "mpv-version");
    fprintf(stdout, "RUNTIME %s network-timeout=%s stream-lavf-o=%s output=null transport-only=1\n", version ? version : "unavailable", argv[2], argv[3]);
    mpv_free(version);
    const char *load[] = {"loadfile", argv[1], "replace", NULL};
    if (mpv_command(m, load) < 0) return 68;
    double started = now(), command_time = 0, last = 0;
    int64_t initial_counter = -1;
    int saw_seek = 0, landed = 0, deadline = 0, ended = 0;
    while (now() - started < 60) {
        mpv_event *event = mpv_wait_event(m, 0.05);
        double position = number(m, "time-pos");
        if (!command_time && position >= 0.4 && flag(m, "seeking") == 0) {
            if (mpv_set_property_string(m, "pause", "yes") < 0) return 69;
            printf("READY paused=1 pos=%.3f\n", position); fflush(stdout);
            // Parent arms/acknowledges the old response stall, then releases this handshake.
            char input[8];
            if (!fgets(input, sizeof(input), stdin) || strcmp(input, "seek\n")) return 70;
            while (mpv_wait_event(m, 0)->event_id != MPV_EVENT_NONE) {}
            int status;
            initial_counter = counter(m, &status);
            state(m, 0, "before-command");
            const char *seek[] = {"seek", "104.146", "absolute", NULL};
            command_time = now();
            int accepted = mpv_command(m, seek);
            printf("COMMAND target=104.146 status=%d monotonic=%.6f initialCounter=%lld\n", accepted, command_time, (long long)initial_counter);
            fflush(stdout);
            if (accepted < 0 || initial_counter < 0) return 71;
            continue;
        }
        if (command_time) {
            double elapsed = now() - command_time;
            if (event->event_id == MPV_EVENT_SEEK) saw_seek = 1;
            if (event->event_id == MPV_EVENT_SEEK || event->event_id == MPV_EVENT_PLAYBACK_RESTART || elapsed - last >= 2) {
                state(m, elapsed, mpv_event_name(event->event_id));
                last = elapsed;
            }
            int status;
            int64_t seeks = counter(m, &status);
            if (saw_seek && event->event_id == MPV_EVENT_PLAYBACK_RESTART && seeks > initial_counter &&
                flag(m, "seeking") == 0 && flag(m, "eof-reached") == 0 && flag(m, "pause") == 1 &&
                isfinite(position) && fabs(position - 104.146) <= 0.5) {
                landed = 1;
                printf("LANDING elapsed=%.3f position=%.3f counterDelta=%lld pausePreserved=1\n", elapsed, position, (long long)(seeks - initial_counter));
                break;
            }
            if (!deadline && elapsed >= 12) {
                deadline = 1; state(m, elapsed, "original-12s-deadline");
                if (permit_deadline) break;
            }
            if (elapsed >= 38) break;
        }
        if (event->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *end = event->data;
            printf("END_FILE reason=%d error=%d\n", end ? end->reason : -1, end ? end->error : -1);
            ended = 1; break;
        }
    }
    printf("RESULT sought=%d sawSeek=%d landed=%d passed12s=%d ended=%d\n", command_time != 0, saw_seek, landed, deadline, ended);
    fflush(stdout);
    mpv_terminate_destroy(m);
    printf("DESTROY complete\n");
    return command_time && (landed || (permit_deadline && (deadline || ended))) ? 0 : 1;
}
