/* Recovery proposal: UNCOMPILED/UNRUN. Real loopback sockets, retained FFmpeg
 * muxer, actual MPV demux producer and a real utility pthread + JOIN. */
/* Fixture checks stay active under a caller's release flags; production TUs
 * are separate and keep their own original assertion/optimization policy. */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/mem.h>
#include "mpv/client.h"
#include "player/client.h"
#include "demux/demux.h"
#include "demux/stheader.h"
#include "misc/thread_tools.h"
#include "mpv_talloc.h"
#include "osdep/timer.h"
#include "stream/stream.h"
#include "genuine_fixture.h"
#include "genuine_observation.h"

int fixture_owned_text_ties(struct mpv_global *, unsigned *, unsigned *);
static const int64_t ordinary_pts[] = {0, 1000, 1000, 4000};
static const int64_t ordinary_duration[] = {700, 900, 1400, 600};
static const int64_t silent_pts[] = {90000, 94000, 99000, 105000, 112000,
                                    120000, 129000, 139000, 150000};
static const int64_t silent_duration[] = {800, 1300, 900, 1700, 1100,
                                         2000, 1200, 1500, 1000};

#define BODY_LIMIT (512u * 1024u)
#define HEADER_LIMIT 8192u
#define CONNECTION_LIMIT 24u
#define CASE_NS INT64_C(6000000000)

static unsigned checks, failures;
static atomic_uint body_waits;
static _Thread_local bool body_phase;
bool genuine_body_phase_active(void) { return body_phase; }
bool genuine_body_phase_set(bool value)
{
    bool old = body_phase;
    body_phase = value;
    return old;
}
void genuine_body_wait_observed(void)
{
    atomic_fetch_add_explicit(&body_waits, 1, memory_order_release);
}
static bool check(bool ok, const char *name)
{
    checks++;
    failures += !ok;
    printf("%s %s\n", ok ? "PASS" : "FAIL", name);
    return ok;
}
static void pause_ms(unsigned ms)
{
    struct timespec ts = {.tv_sec = ms / 1000, .tv_nsec = (long)(ms % 1000) * 1000000};
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}
struct memory_file { uint8_t *bytes; size_t size, capacity, position; };
static int memory_read(void *opaque, uint8_t *dst, int bytes)
{
    struct memory_file *m = opaque;
    if (bytes <= 0) return AVERROR(EINVAL);
    if (m->position >= m->size) return AVERROR_EOF;
    size_t count = m->size - m->position;
    if (count > (size_t)bytes) count = (size_t)bytes;
    memcpy(dst, m->bytes + m->position, count);
    m->position += count;
    return (int)count;
}
static int memory_write(void *opaque, const uint8_t *src, int bytes)
{
    struct memory_file *m = opaque;
    if (bytes < 0 || (size_t)bytes > BODY_LIMIT - m->position)
        return AVERROR(ENOBUFS);
    size_t end = m->position + (size_t)bytes;
    if (end > m->capacity) {
        size_t capacity = end < 4096 ? 4096 : end;
        uint8_t *next = av_realloc(m->bytes, capacity);
        if (!next) return AVERROR(ENOMEM);
        m->bytes = next;
        m->capacity = capacity;
    }
    if (m->position > m->size)
        memset(m->bytes + m->size, 0, m->position - m->size);
    memcpy(m->bytes + m->position, src, (size_t)bytes);
    m->position = end;
    if (end > m->size) m->size = end;
    return bytes;
}
static int64_t memory_seek(void *opaque, int64_t offset, int whence)
{
    struct memory_file *m = opaque;
    if (whence == AVSEEK_SIZE) return (int64_t)m->size;
    whence &= ~AVSEEK_FORCE;
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ?
                   (int64_t)m->position : whence == SEEK_END ? (int64_t)m->size : -1;
    if (base < 0 || offset < -base || offset > (int64_t)BODY_LIMIT - base)
        return AVERROR(EINVAL);
    m->position = (size_t)(base + offset);
    return (int64_t)m->position;
}
/* A negative duration case is meaningful only if the real mux/demux actually
 * retains its zero duration. Fail a prerequisite, never blame the reader, if
 * Matroska or an upstream version transforms the intended packet corpus. */
static int verify_media(const struct memory_file *media, unsigned tracks, bool zero, bool silent)
{
    const int64_t *pts = silent ? silent_pts : ordinary_pts;
    const int64_t *duration = silent ? silent_duration : ordinary_duration;
    unsigned cues = silent ? 9 : 4;
    struct memory_file cursor = *media;
    cursor.position = 0;
    AVFormatContext *fmt = avformat_alloc_context();
    AVPacket *packet = av_packet_alloc();
    uint8_t *buffer = av_malloc(4096);
    AVIOContext *io = NULL;
    unsigned seen[3] = {0};
    int rc = AVERROR(ENOMEM);
    if (!fmt || !packet || !buffer ||
        !(io = avio_alloc_context(buffer, 4096, 0, &cursor, memory_read, NULL, memory_seek)))
        goto done;
    buffer = NULL;
    io->seekable = AVIO_SEEKABLE_NORMAL;
    fmt->pb = io;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *format = av_find_input_format("matroska");
    if (!format || (rc = avformat_open_input(&fmt, NULL, format, NULL)) < 0)
        goto done;
    if (fmt->nb_streams != tracks + (silent ? 1u : 0u)) { rc = AVERROR_INVALIDDATA; goto done; }
    while ((rc = av_read_frame(fmt, packet)) >= 0) {
        int n = packet->stream_index;
        if (silent && n == (int)tracks) {
            if (++seen[n] != 1 || packet->pts != 0 || packet->size != 1600 ||
                fmt->streams[n]->codecpar->codec_id != AV_CODEC_ID_PCM_S16LE) {
                rc = AVERROR_INVALIDDATA; goto done;
            }
            av_packet_unref(packet);
            continue;
        }
        if (n < 0 || (unsigned)n >= tracks || seen[n] >= cues ||
            fmt->streams[n]->codecpar->codec_id != AV_CODEC_ID_SUBRIP) {
            rc = AVERROR_INVALIDDATA; goto done;
        }
        unsigned cue = seen[n]++;
        AVRational tb = fmt->streams[n]->time_base;
        if (av_rescale_q(packet->pts, tb, (AVRational){1, 1000}) != pts[cue] ||
            av_rescale_q(packet->duration, tb, (AVRational){1, 1000}) !=
                (zero && cue == 1 ? 0 : duration[cue])) {
            rc = AVERROR_INVALIDDATA; goto done;
        }
        av_packet_unref(packet);
    }
    if (rc == AVERROR_EOF)
        rc = seen[0] == cues && (tracks == 1 || seen[1] == cues) &&
             (!silent || seen[tracks] == 1) ? 0 : AVERROR_INVALIDDATA;
done:
    av_packet_free(&packet);
    avformat_close_input(&fmt);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(buffer);
    return rc;
}
/* Genuine Matroska muxing into a bounded custom AVIO, no ffmpeg process.
 * Equal PTS and distinct real packet durations are deliberate decoder cases. */
static int make_media(struct memory_file *m, bool two_tracks, bool zero_duration, bool silent)
{
    const int64_t *pts = silent ? silent_pts : ordinary_pts;
    const int64_t *duration = silent ? silent_duration : ordinary_duration;
    unsigned cues = silent ? 9 : 4;
    AVFormatContext *fmt = NULL;
    AVIOContext *io = NULL;
    AVPacket *packet = NULL;
    uint8_t *buffer = NULL;
    int rc = avformat_alloc_output_context2(&fmt, NULL, "matroska", NULL);
    if (rc < 0 || !fmt) return rc < 0 ? rc : AVERROR(ENOMEM);
    unsigned tracks = two_tracks ? 2 : 1;
    for (unsigned n = 0; n < tracks; n++) {
        AVStream *s = avformat_new_stream(fmt, NULL);
        if (!s) { rc = AVERROR(ENOMEM); goto done; }
        s->time_base = (AVRational){1, 1000};
        s->codecpar->codec_type = AVMEDIA_TYPE_SUBTITLE;
        s->codecpar->codec_id = AV_CODEC_ID_SUBRIP;
        s->disposition = n ? 0 : AV_DISPOSITION_DEFAULT;
        if ((rc = av_dict_set(&s->metadata, "language", n ? "de" : "en", 0)) < 0) goto done;
    }
    if (silent) {
        /* A genuine PCM packet at zero establishes the timeline origin. Merely
         * moving the first subtitle in a subtitle-only container can rebase
         * start_time to90 and would not test a90-second silent intro. */
        AVStream *audio = avformat_new_stream(fmt, NULL);
        if (!audio) { rc = AVERROR(ENOMEM); goto done; }
        audio->time_base = (AVRational){1, 8000};
        audio->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
        audio->codecpar->codec_id = AV_CODEC_ID_PCM_S16LE;
        audio->codecpar->format = AV_SAMPLE_FMT_S16;
        audio->codecpar->sample_rate = 8000;
        audio->codecpar->bits_per_coded_sample = 16;
        audio->codecpar->bits_per_raw_sample = 16;
        audio->codecpar->block_align = 2;
        audio->codecpar->bit_rate = 128000;
        av_channel_layout_default(&audio->codecpar->ch_layout, 1);
    }
    buffer = av_malloc(4096);
    packet = av_packet_alloc();
    if (!buffer || !packet || !(io = avio_alloc_context(buffer, 4096, 1, m,
                                             NULL, memory_write, memory_seek))) {
        rc = AVERROR(ENOMEM); goto done;
    }
    buffer = NULL;
    io->seekable = AVIO_SEEKABLE_NORMAL;
    fmt->pb = io;
    fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    if ((rc = avformat_write_header(fmt, NULL)) < 0) goto done;
    if (silent) {
        if ((rc = av_new_packet(packet, 1600)) < 0) goto done;
        memset(packet->data, 0, 1600);
        packet->stream_index = (int)tracks;
        packet->pts = packet->dts = 0;
        packet->duration = 800;
        packet->flags = AV_PKT_FLAG_KEY;
        av_packet_rescale_ts(packet, (AVRational){1, 8000}, fmt->streams[tracks]->time_base);
        if ((rc = av_interleaved_write_frame(fmt, packet)) < 0) goto done;
    }
    for (unsigned cue = 0; cue < cues; cue++) {
        for (unsigned track = 0; track < tracks; track++) {
            const char text[] = "genuine embedded text";
            if ((rc = av_new_packet(packet, sizeof(text) - 1)) < 0) goto done;
            memcpy(packet->data, text, sizeof(text) - 1);
            packet->pts = packet->dts = pts[cue];
            packet->duration = zero_duration && cue == 1 ? 0 : duration[cue];
            packet->stream_index = (int)track;
            packet->flags = AV_PKT_FLAG_KEY;
            av_packet_rescale_ts(packet, (AVRational){1, 1000}, fmt->streams[track]->time_base);
            if ((rc = av_interleaved_write_frame(fmt, packet)) < 0) goto done;
        }
    }
    if ((rc = av_write_trailer(fmt)) < 0) goto done;
    avio_flush(io);
    rc = io->error < 0 ? io->error : m->size ? 0 : AVERROR_INVALIDDATA;
done:
    av_packet_free(&packet);
    fmt->pb = NULL;
    avformat_free_context(fmt);
    if (io) av_freep(&io->buffer);
    avio_context_free(&io);
    av_free(buffer);
    if (rc >= 0) rc = verify_media(m, tracks, zero_duration, silent);
    if (rc < 0) { av_freep(&m->bytes); *m = (struct memory_file){0}; }
    return rc;
}

enum response_mode { RESPONSE_GOOD, RESPONSE_ETAG_CHANGED, RESPONSE_TRUNCATED,
                     RESPONSE_STALL, RESPONSE_REDIRECT };
struct server {
    pthread_t thread;
    pthread_mutex_t lock;
    atomic_bool stop;
    int listener, active;
    bool started, raw, wire_ok, duplicate_headers_sent, duplicate_peer_closed;
    unsigned requests, duplicate_requests;
    const char *raw_first, *raw_second;
    const struct memory_file *media;
    enum response_mode mode;
    char url[96], host[64];
};
static bool send_bytes(int fd, const void *data, size_t bytes)
{
    const uint8_t *p = data;
    while (bytes) {
        ssize_t n = send(fd, p, bytes, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n;
        bytes -= (size_t)n;
    }
    return true;
}
static bool header_line(const char *headers, const char *name, const char *value)
{
    char wanted[256];
    int n = snprintf(wanted, sizeof(wanted), "\r\n%s: %s\r\n", name, value);
    return n > 0 && (size_t)n < sizeof(wanted) && strstr(headers, wanted);
}
static bool receive_headers(struct server *s, int fd, char text[HEADER_LIMIT])
{
    size_t used = 0;
    int64_t deadline = mp_time_ns() + CASE_NS;
    while (!atomic_load(&s->stop) && mp_time_ns() < deadline && used + 1 < HEADER_LIMIT) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        int rc = poll(&p, 1, 20);
        if (rc < 0 && errno == EINTR) continue;
        if (rc <= 0) continue;
        ssize_t n = recv(fd, text + used, HEADER_LIMIT - 1 - used, 0);
        if (n <= 0) return false;
        used += (size_t)n;
        text[used] = 0;
        if (strstr(text, "\r\n\r\n")) return true;
    }
    return false;
}
static bool read_range(const char *request, uint64_t *start, uint64_t *end)
{
    const char *line = strstr(request, "\r\nRange: bytes=");
    *start = 0;
    *end = UINT64_MAX;
    if (!line) return true;
    line += strlen("\r\nRange: bytes=");
    char *tail = NULL;
    errno = 0;
    *start = strtoull(line, &tail, 10);
    if (errno || tail == line || *tail != '-') return false;
    line = tail + 1;
    if (*line != '\r') {
        errno = 0;
        *end = strtoull(line, &tail, 10);
        if (errno || tail == line) return false;
        line = tail;
    }
    return line[0] == '\r' && line[1] == '\n' && *end >= *start;
}
static void serve_connection(struct server *s, int fd)
{
    char request[HEADER_LIMIT] = {0};
    if (!receive_headers(s, fd, request)) return;
    bool duplicate = strstr(request, "\r\nIf-Match:") != NULL;
    bool good = !strncmp(request, "GET /finite HTTP/1.1\r\n", 22) &&
                header_line(request, "Host", s->host) &&
                header_line(request, "Accept-Encoding", "identity");
    if (duplicate) good = good && header_line(request, "If-Match", "\"fixture-v1\"");
    pthread_mutex_lock(&s->lock);
    unsigned ordinal = ++s->requests;
    if (duplicate) s->duplicate_requests++;
    s->wire_ok = s->wire_ok && good && ordinal <= CONNECTION_LIMIT;
    pthread_mutex_unlock(&s->lock);
    if (!good || ordinal > CONNECTION_LIMIT) return;
    if (s->raw) {
        pthread_mutex_lock(&s->lock);
        s->wire_ok = s->wire_ok && (ordinal != 2 ||
            (duplicate && header_line(request, "Range", "bytes=0-63")));
        pthread_mutex_unlock(&s->lock);
        const char *text = ordinal == 1 ? s->raw_first : s->raw_second;
        if (ordinal <= 2) send_bytes(fd, text, strlen(text));
        return;
    }
    uint64_t start, end;
    if (!s->media || !s->media->size || !read_range(request, &start, &end) ||
        start >= s->media->size) return;
    if (end >= s->media->size) end = s->media->size - 1;
    size_t bytes = (size_t)(end - start + 1);
    char header[512];
    if (duplicate && s->mode == RESPONSE_REDIRECT) {
        const char text[] = "HTTP/1.1 302 Found\r\nLocation: /different\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        send_bytes(fd, text, sizeof(text) - 1);
        return;
    }
    const char *tag = duplicate && s->mode == RESPONSE_ETAG_CHANGED ?
                      "\"fixture-v2\"" : "\"fixture-v1\"";
    int n = snprintf(header, sizeof(header),
        "HTTP/1.1 206 Partial Content\r\nETag: %s\r\nAccept-Ranges: bytes\r\n"
        "Content-Length: %zu\r\nContent-Range: bytes %" PRIu64 "-%" PRIu64 "/%zu\r\n"
        "Content-Encoding: identity\r\nConnection: close\r\n\r\n",
        tag, bytes, start, end, s->media->size);
    if (n <= 0 || (size_t)n >= sizeof(header) || !send_bytes(fd, header, (size_t)n)) return;
    pthread_mutex_lock(&s->lock);
    if (duplicate) s->duplicate_headers_sent = true;
    pthread_mutex_unlock(&s->lock);
    if (duplicate && s->mode == RESPONSE_STALL) {
        while (!atomic_load(&s->stop)) {
            struct pollfd p = {.fd = fd, .events = POLLIN};
            if (poll(&p, 1, 10) > 0) {
                char byte;
                if (recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0) {
                    pthread_mutex_lock(&s->lock);
                    s->duplicate_peer_closed = true;
                    pthread_mutex_unlock(&s->lock);
                    break;
                }
            }
        }
        return;
    }
    if (duplicate && s->mode == RESPONSE_TRUNCATED) bytes /= 2;
    send_bytes(fd, s->media->bytes + start, bytes);
}
static void *server_thread(void *opaque)
{
    struct server *s = opaque;
    int64_t deadline = mp_time_ns() + INT64_C(12000000000);
    while (!atomic_load(&s->stop) && mp_time_ns() < deadline) {
        struct pollfd p = {.fd = s->listener, .events = POLLIN};
        if (poll(&p, 1, 20) <= 0) continue;
        int fd = accept(s->listener, NULL, NULL);
        if (fd < 0) continue;
        struct timeval send_timeout = {.tv_sec = 2};
        if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send_timeout, sizeof(send_timeout)) < 0) {
            pthread_mutex_lock(&s->lock);
            s->wire_ok = false;
            pthread_mutex_unlock(&s->lock);
            close(fd);
            continue;
        }
#ifdef SO_NOSIGPIPE
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#endif
        pthread_mutex_lock(&s->lock);
        s->active = fd;
        pthread_mutex_unlock(&s->lock);
        serve_connection(s, fd);
        pthread_mutex_lock(&s->lock);
        s->active = -1;
        close(fd); // lock prevents finish from shutting down a reused descriptor
        pthread_mutex_unlock(&s->lock);
    }
    return NULL;
}
static int server_start(struct server *s)
{
    struct sockaddr_in address = {.sin_family = AF_INET,
                                 .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t size = sizeof(address);
    s->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (s->listener < 0) return AVERROR(errno);
    if (fcntl(s->listener, F_SETFL, O_NONBLOCK) < 0 ||
        bind(s->listener, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        getsockname(s->listener, (struct sockaddr *)&address, &size) < 0 ||
        listen(s->listener, 4) < 0) {
        int rc = AVERROR(errno);
        close(s->listener); s->listener = -1;
        return rc;
    }
    snprintf(s->host, sizeof(s->host), "127.0.0.1:%u", ntohs(address.sin_port));
    snprintf(s->url, sizeof(s->url), "http://%s/finite", s->host);
    int rc = pthread_create(&s->thread, NULL, server_thread, s);
    if (rc) { close(s->listener); s->listener = -1; return AVERROR(rc); }
    s->started = true;
    return 0;
}
static int raw_start(void *opaque, const char *first, const char *second)
{
    struct server *s = opaque;
    s->raw = true;
    s->raw_first = first;
    s->raw_second = second;
    return server_start(s);
}
static int server_finish(void *opaque)
{
    struct server *s = opaque;
    atomic_store(&s->stop, true);
    if (s->started) {
        pthread_mutex_lock(&s->lock);
        if (s->active >= 0) shutdown(s->active, SHUT_RDWR);
        pthread_mutex_unlock(&s->lock);
        shutdown(s->listener, SHUT_RDWR);
        int rc = pthread_join(s->thread, NULL);
        close(s->listener);
        s->listener = -1;
        s->started = false;
        if (rc) return AVERROR(rc);
    }
    return s->wire_ok && (!s->raw || s->requests == 2) ? 0 : AVERROR_INVALIDDATA;
}

/* Consumer/worker implementation follows; no fake MPContext getter is needed:
 * player/client.h already exposes the real internal mp_client_get_global. */
struct consumer {
    struct demuxer *demux;
    pthread_t owner;
    atomic_uint wakeups, foreign_wakes;
    int64_t until;
};
unsigned genuine_foreign_demux_wakes(void *opaque)
{
    struct consumer *c = opaque;
    return atomic_load_explicit(&c->foreign_wakes, memory_order_acquire);
}
static void wake_consumer(void *opaque)
{
    struct consumer *c = opaque;
    if (!pthread_equal(pthread_self(), c->owner))
        atomic_fetch_add_explicit(&c->foreign_wakes, 1, memory_order_release);
    atomic_fetch_add_explicit(&c->wakeups, 1, memory_order_release);
}
static void pump_consumer(void *opaque)
{
    struct consumer *c = opaque;
    assert(mp_time_ns() < c->until);
    unsigned start = atomic_load_explicit(&c->wakeups, memory_order_acquire);
    int64_t until = mp_time_ns() + INT64_C(10000000);
    while (atomic_load_explicit(&c->wakeups, memory_order_acquire) == start &&
           mp_time_ns() < until) pause_ms(1);
    demux_update(c->demux, MP_NOPTS_VALUE); // actual consumer refresh after wake/timer
}
struct worker { void (*function)(void *); void *opaque; };
static void *worker_entry(void *opaque)
{
    struct worker *worker = opaque;
    worker->function(worker->opaque);
    return NULL;
}
static void run_and_join(void (*function)(void *), void *opaque)
{
    struct worker worker = {function, opaque};
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker_entry, &worker)) abort();
    if (pthread_join(thread, NULL)) abort();
}
struct running_reader { struct demux_reference_request *request; bool decoded; };
static void run_reader(void *opaque)
{
    struct running_reader *r = opaque;
    r->decoded = demux_reference_reader_run(r->request);
}
static bool stream_options(mpv_handle *client)
{
    char key_storage[][32] = {"http_proxy", "protocol_whitelist", "headers", "reconnect"};
    char text_storage[][64] = {"", "http,tcp", "Accept-Encoding: identity\r\n", "0"};
    char *keys[4];
    mpv_node values[4];
    for (unsigned n = 0; n < 4; n++) {
        keys[n] = key_storage[n];
        values[n] = (mpv_node){.format = MPV_FORMAT_STRING, .u.string = text_storage[n]};
    }
    mpv_node_list map = {.num = 4, .keys = keys, .values = values};
    mpv_node node = {.format = MPV_FORMAT_NODE_MAP, .u.list = &map};
    return mpv_set_option(client, "stream-lavf-o", MPV_FORMAT_NODE, &node) >= 0;
}
enum demux_case { CASE_EQUAL_PTS, CASE_CHANGED_ETAG, CASE_SHORT_BODY,
                 CASE_CANCEL_BODY, CASE_DEADLINE_BODY, CASE_RESET_BODY,
                 CASE_SELECTED_TRACK, CASE_ZERO_DURATION, CASE_REDIRECT, CASE_SILENT_INTRO };
static bool wait_body_read(struct server *s, struct consumer *c, unsigned before)
{
    while (mp_time_ns() < c->until) {
        pthread_mutex_lock(&s->lock);
        bool seen = s->duplicate_headers_sent;
        pthread_mutex_unlock(&s->lock);
        if (seen && atomic_load_explicit(&body_waits, memory_order_acquire) > before)
            return true;
        pump_consumer(c);
    }
    return false;
}
static bool demux_case(enum demux_case kind)
{
    struct memory_file media = {0};
    struct server s = {.listener = -1, .active = -1, .wire_ok = true};
    struct consumer consumer = {.owner = pthread_self(), .until = mp_time_ns() + CASE_NS};
    mpv_handle *client = NULL;
    struct mp_cancel *cancel = NULL;
    struct demuxer *demux = NULL;
    struct demux_reference_request *request = NULL;
    struct demux_reference_result result = {0};
    struct running_reader reader = {0};
    pthread_t worker;
    bool started = false, ok = false;
    atomic_init(&s.stop, false);
    atomic_init(&consumer.wakeups, 0);
    atomic_init(&consumer.foreign_wakes, 0);
    if (pthread_mutex_init(&s.lock, NULL)) return false;
    if (make_media(&media, kind == CASE_SELECTED_TRACK, kind == CASE_ZERO_DURATION,
                   kind == CASE_SILENT_INTRO) < 0)
        goto done;
    s.media = &media;
    s.mode = kind == CASE_CHANGED_ETAG ? RESPONSE_ETAG_CHANGED :
             kind == CASE_SHORT_BODY ? RESPONSE_TRUNCATED :
             kind == CASE_REDIRECT ? RESPONSE_REDIRECT :
             kind >= CASE_CANCEL_BODY && kind <= CASE_RESET_BODY ? RESPONSE_STALL : RESPONSE_GOOD;
    if (server_start(&s) < 0 || !(client = mpv_create())) goto done;
    const char *names[] = {"config", "load-scripts", "terminal", "vo", "ao", "idle"};
    const char *values[] = {"no", "no", "no", "null", "null", "yes"};
    for (unsigned n = 0; n < 6; n++)
        if (mpv_set_option_string(client, names[n], values[n]) < 0) goto done;
    if (!stream_options(client) || mpv_initialize(client) < 0 || !(cancel = mp_cancel_new(NULL)))
        goto done;
    char format[] = "lavf";
    struct demuxer_params params = {.force_format = format, .stream_flags = STREAM_ORIGIN_DIRECT};
    demux = demux_open_url(s.url, &params, cancel, mp_client_get_global(client));
    if (!demux || !demux->seekable) goto done;
    consumer.demux = demux;
    demux_set_wakeup_cb(demux, wake_consumer, &consumer);
    int selected = -1;
    for (int n = 0; n < demux_get_num_stream(demux); n++) {
        struct sh_stream *stream = demux_get_stream(demux, n);
        if (stream->type == STREAM_SUB) {
            if (selected < 0) selected = n;
            demuxer_select_track(demux, stream, MP_NOPTS_VALUE,
                                 n == selected || kind == CASE_SELECTED_TRACK);
        }
    }
    if (selected < 0) goto done;
    demux_start_thread(demux);
    demux_start_prefetch(demux);
    struct sh_stream *track = demux_get_stream(demux, selected);
    bool observed_packet = false;
    while (!observed_packet && mp_time_ns() < consumer.until) {
        struct demux_packet *packet = NULL;
        int rc = demux_read_packet_async(track, &packet);
        observed_packet = rc > 0 && packet;
        free_demux_packet(packet);
        if (rc < 0) break;
        pump_consumer(&consumer);
    }
    if (!observed_packet || !genuine_foreign_demux_wakes(&consumer)) goto done;
    if (kind == CASE_EQUAL_PTS || kind == CASE_SILENT_INTRO) {
        ok = fixture_real_reader_roundtrip(demux, selected,
             mp_time_ns() + INT64_C(3000000000), pump_consumer, &consumer, run_and_join, &result);
        bool silent = kind == CASE_SILENT_INTRO;
        const int64_t *expected = silent ? silent_pts : ordinary_pts;
        const int64_t *duration = silent ? silent_duration : ordinary_duration;
        unsigned cues = silent ? 9 : 4;
        ok = ok && result.num_pairs == cues && result.complete &&
             result.prefix_start_ms == 0 && result.prefix_end_ms == 1080000 &&
             (!silent || result.origin_seconds == 0);
        for (unsigned n = 0; ok && n < cues; n++)
            ok = result.pairs[n].start_ms == expected[n] &&
                 result.pairs[n].end_ms == expected[n] + duration[n];
        goto done;
    }
    int64_t deadline = mp_time_ns() + (kind == CASE_DEADLINE_BODY ?
                        INT64_C(800000000) : INT64_C(3000000000));
    unsigned capture_wakes = genuine_foreign_demux_wakes(&consumer);
    request = demux_reference_reader_request(demux, selected, deadline);
    if (!request) goto done;
    while (demux_reference_reader_status(request) == DEMUX_REFERENCE_READER_PENDING ||
           genuine_foreign_demux_wakes(&consumer) == capture_wakes)
        pump_consumer(&consumer);
    if (kind == CASE_SELECTED_TRACK) {
        ok = demux_reference_reader_status(request) == DEMUX_REFERENCE_READER_UNAVAILABLE &&
             !demux_reference_reader_run(request) && !demux_reference_reader_take(request, &result);
        goto done;
    }
    if (demux_reference_reader_status(request) != DEMUX_REFERENCE_READER_CAPTURED) goto done;
    reader.request = request;
    struct worker launch = {run_reader, &reader};
    unsigned body_before = atomic_load_explicit(&body_waits, memory_order_acquire);
    if (pthread_create(&worker, NULL, worker_entry, &launch)) goto done;
    started = true;
    if (kind >= CASE_CANCEL_BODY && kind <= CASE_RESET_BODY) {
        if (!wait_body_read(&s, &consumer, body_before)) goto done;
        if (demux_reference_reader_status(request) != DEMUX_REFERENCE_READER_RUNNING)
            goto done;
        if (kind == CASE_CANCEL_BODY) demux_reference_request_cancel(request);
        if (kind == CASE_RESET_BODY) demux_flush(demux);
    }
    if (pthread_join(worker, NULL)) abort();
    started = false;
    ok = !reader.decoded && !demux_reference_reader_revalidate(demux, request) &&
         !demux_reference_reader_take(request, &result);
    if (kind == CASE_CANCEL_BODY || kind == CASE_RESET_BODY || kind == CASE_DEADLINE_BODY)
        ok = ok && demux_reference_request_cancelled(request);
    if (kind == CASE_CANCEL_BODY || kind == CASE_RESET_BODY) {
        /* Server has sent only real response headers and has not released a
         * single body byte. Reader close/JOIN must precede its original limit. */
        while (ok && mp_time_ns() < deadline) {
            pthread_mutex_lock(&s.lock);
            bool closed = s.duplicate_peer_closed;
            pthread_mutex_unlock(&s.lock);
            if (closed) break;
            pause_ms(1);
        }
        pthread_mutex_lock(&s.lock);
        ok = ok && s.duplicate_peer_closed && !atomic_load(&s.stop) && mp_time_ns() < deadline;
        pthread_mutex_unlock(&s.lock);
    }
done:
    if (started) {
        demux_reference_request_cancel(request);
        if (pthread_join(worker, NULL)) abort();
    }
    if (request) {
        demux_reference_request_cancel(request);
        demux_reference_request_release(&request);
    }
    if (demux) {
        demux_set_wakeup_cb(demux, NULL, NULL);
        demux_cancel_and_free(demux); // real producer JOIN before global/free
    }
    talloc_free(cancel);
    if (client) mpv_terminate_destroy(client);
    int server_rc = server_finish(&s);
    ok = ok && server_rc >= 0 && s.requests > 0;
    ok = ok && s.duplicate_requests == (kind == CASE_SELECTED_TRACK ? 0u : 1u);
    pthread_mutex_destroy(&s.lock);
    av_free(media.bytes); // all HTTP/native worker/server/producer uses finished
    return ok;
}
static void run_native_cue_fixture(void)
{
    mpv_handle *client = mpv_create();
    bool ready = client != NULL;
    const char *names[] = {"config", "load-scripts", "terminal", "vo", "ao", "idle"};
    const char *values[] = {"no", "no", "no", "null", "null", "yes"};
    for (unsigned n = 0; ready && n < 6; n++)
        ready = mpv_set_option_string(client, names[n], values[n]) >= 0;
    ready = ready && mpv_initialize(client) >= 0;
    if (ready)
        ready = fixture_owned_text_ties(mp_client_get_global(client), &checks, &failures) == 0;
    check(ready, "real-native-owned-text-ties-called-on-retained-global");
    if (client) mpv_terminate_destroy(client);
}
int main(void)
{
    run_native_cue_fixture();
    unsigned raw_count = genuine_http_case_count();
    for (unsigned n = 0; n < raw_count; n++) {
        struct server s = {.listener = -1, .active = -1, .wire_ok = true};
        atomic_init(&s.stop, false);
        if (pthread_mutex_init(&s.lock, NULL)) return 2;
        struct vortx_reference_fixture_rig rig = {&s, s.url, raw_start, server_finish};
        /* The fixture's early URL argument guard precedes serve_two. The real
         * listener replaces this placeholder before the first native open. */
        snprintf(s.url, sizeof(s.url), "http://127.0.0.1:0/finite");
        int rc = vortx_reference_fixture_run_case(&rig, n);
        char name[64];
        snprintf(name, sizeof(name), "real-http-framing-case-%u", n);
        check(rc == 0, name);
        pthread_mutex_destroy(&s.lock);
    }
    static const char *names[] = {"real-demux-equal-pts-known-durations",
        "real-demux-entity-change", "real-demux-short-body", "real-demux-cancel-during-body",
        "real-demux-deadline-during-body", "real-demux-owner-reset-during-body",
        "real-demux-two-selected-tracks", "real-demux-unknown-duration", "real-demux-redirect-refused",
        "real-demux-first-cue90s-eight-irregular-later-cues-origin0"};
    for (unsigned n = 0; n < sizeof(names) / sizeof(names[0]); n++)
        check(demux_case((enum demux_case)n), names[n]);
    printf("RESULT checks=%u failures=%u real_loopback=true real_demux_queue=true "
           "worker_join=true external_network=false full_alignment=false\n", checks, failures);
    return failures ? 1 : 0;
}
