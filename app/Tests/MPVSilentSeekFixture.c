// Headless diagnostic fixture: synthetic local HTTP media only; no app, windows or audio device.
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double clock_seconds(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static double number(mpv_handle *m, const char *key) {
    double value = -1;
    mpv_get_property(m, key, MPV_FORMAT_DOUBLE, &value);
    return value;
}
static int flag(mpv_handle *m, const char *key) {
    int value = -1;
    mpv_get_property(m, key, MPV_FORMAT_FLAG, &value);
    return value;
}
static long long integer(mpv_handle *m, const char *key) {
    int64_t value = -1;
    mpv_get_property(m, key, MPV_FORMAT_INT64, &value);
    return (long long)value;
}
int main(int argc, char **argv) {
    if ((argc != 4 && argc != 5) || strncmp(argv[1], "http://127.0.0.1:", 17)) return 64;
    int expect_stalled = strcmp(argv[3], "expect-stalled") == 0;
    int paused = argc == 5 && strcmp(argv[4], "playing") != 0;
    int overlapping = argc == 5 && strcmp(argv[4], "overlap-paused") == 0;
    mpv_handle *m = mpv_create();
    if (!m) return 65;
    mpv_set_option_string(m, "vo", "null");
    mpv_set_option_string(m, "ao", "null");
    mpv_set_option_string(m, "terminal", "no");
    mpv_set_option_string(m, "config", "no");
    mpv_set_option_string(m, "network-timeout", "30");
    mpv_set_option_string(m, "stream-lavf-o", argv[2]);
    mpv_set_option_string(m, "demuxer-readahead-secs", "300");
    mpv_set_option_string(m, "demuxer-max-bytes", "256MiB");
    if (mpv_initialize(m) < 0) return 66;
    char *version = mpv_get_property_string(m, "mpv-version");
    char *ffmpeg = mpv_get_property_string(m, "ffmpeg-version");
    printf("artifact mpv=%s ffmpeg=%s\n", version ? version : "?", ffmpeg ? ffmpeg : "?");
    mpv_free(version); mpv_free(ffmpeg);
    const char *load[] = {"loadfile", argv[1], "replace", NULL};
    if (mpv_command(m, load) < 0) return 67;
    double started = clock_seconds(), sought = 0, last = 0;
    int seek_seen = 0, settled = 0, stalled_at_deadline = 0, resumed = 0;
    while (clock_seconds() - started < 42) {
        mpv_event *e = mpv_wait_event(m, 0.1);
        double now = clock_seconds(), pos = number(m, "time-pos");
        if (!sought && pos >= 0.4 && !flag(m, "seeking")) {
            if (paused && mpv_set_property_string(m, "pause", "yes") < 0) return 68;
            if (overlapping) {
                const char *earlier[] = {"seek", "80.125", "absolute+exact", NULL};
                if (mpv_command(m, earlier) < 0) return 69;
            }
            const char *seek[] = {"seek", "104.146", "absolute", NULL};
            int result = mpv_command(m, seek);
            sought = now;
            printf("command at=%.3f from=%.3f status=%d\n", now-started, pos, result);
        }
        if (sought && e->event_id == MPV_EVENT_SEEK) seek_seen = 1;
        if (sought && (e->event_id == MPV_EVENT_SEEK || e->event_id == MPV_EVENT_PLAYBACK_RESTART || now-last >= 2)) {
            printf("native event=%s elapsed=%.3f pos=%.3f seeking=%d eof=%d paused=%d cache=%.3f demuxSeeking=%.3f seeks=%lld\n",
                mpv_event_name(e->event_id), now-sought, pos, flag(m, "seeking"), flag(m, "eof-reached"),
                flag(m, "pause"),
                number(m, "demuxer-cache-duration"), number(m, "demuxer-cache-state/debug-seeking"),
                integer(m, "demuxer-cache-state/debug-low-level-seeks"));
            fflush(stdout); last = now;
        }
        if (sought && seek_seen && e->event_id == MPV_EVENT_PLAYBACK_RESTART
            && flag(m, "seeking") == 0 && flag(m, "eof-reached") == 0 && pos >= 103 && pos < 107) {
            settled = 1;
            if (!paused) break;
            if (flag(m, "pause") != 1) return 70;
            printf("parked target=104.146 pos=%.3f pausePreserved=1 overlap=%d\n", pos, overlapping);
            if (mpv_set_property_string(m, "pause", "no") < 0) return 71;
        }
        if (paused && settled && pos >= 105.146 && flag(m, "seeking") == 0) { resumed = 1; break; }
        if (sought && now - sought >= 12) {
            stalled_at_deadline = seek_seen && flag(m, "seeking") == 1 && flag(m, "eof-reached") == 0;
            printf("deadline target=104.146 observedStall=%d pos=%.3f seeking=%d eof=%d\n",
                stalled_at_deadline, pos, flag(m, "seeking"), flag(m, "eof-reached"));
            break;
        }
        if (e->event_id == MPV_EVENT_END_FILE) break;
    }
    int passed = expect_stalled ? stalled_at_deadline && !settled : settled && (!paused || resumed);
    printf("result settled=%d resumed=%d expectedStall=%d pass=%d\n", settled, resumed, expect_stalled, passed);
    mpv_terminate_destroy(m);
    return passed ? 0 : 1;
}
