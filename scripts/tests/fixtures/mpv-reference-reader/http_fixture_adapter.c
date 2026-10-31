/* SOURCE PROPOSAL ONLY: UNCOMPILED/UNRUN. No fixture receipt is claimed.
 * Intended for a future matched libavformat test translation unit including
 * the complete afterimage http.c (rather than copied model state). Link the
 * matching URL/AVIO/TCP/TLS objects, excluding a second http.o. The runner's
 * rig serves the raw strings over a real local TCP listener, handles exactly
 * two requests, and records the received Host/If-Match/Range/identity headers.
 * No fake AVIO/URLContext/sent-request/transport object is accepted here.
 * This file contains no main() and launches nothing merely by being retained.
 */
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <assert.h>
#include "genuine_observation.h"
#ifndef GENUINE_HTTP_SOURCE
#error "Root must bind GENUINE_HTTP_SOURCE to the accepted canonical HTTP successor"
#endif
/* The real body is renamed only in this whole-TU fixture, with every original
 * statement intact. External native consumers call the thin observer below. */
#define avpriv_vortx_reference_read_v1 fixture_original_reference_read_v1
#include GENUINE_HTTP_SOURCE
#undef avpriv_vortx_reference_read_v1

/* The included FFmpeg internal.h can define NDEBUG again. Reinstall assert
 * only AFTER the complete production TU and all its headers; the production
 * body above retains its original policy. No more headers follow this point. */
#undef NDEBUG
#include <assert.h>
#ifdef NDEBUG
#error "The genuine HTTP fixture requires active assertions after all headers"
#endif
#ifndef assert
#error "The genuine HTTP fixture requires the standard assert macro"
#endif

int avpriv_vortx_reference_read_v1(struct avpriv_vortx_reference_reader *,
                                  unsigned char *, int);
int avpriv_vortx_reference_read_v1(struct avpriv_vortx_reference_reader *reader,
                                  unsigned char *buffer, int bytes)
{
    bool previous = genuine_body_phase_set(true);
    int result = fixture_original_reference_read_v1(reader, buffer, bytes);
    genuine_body_phase_set(previous);
    return result;
}

unsigned genuine_http_case_count(void);
int vortx_reference_fixture_lifetime_action(AVIOContext *,
    struct avpriv_vortx_reference_recipe *, int, const char *);
void vortx_reference_fixture_lifetime_has_no_work_expiry(
    struct avpriv_vortx_reference_recipe *);

struct vortx_reference_fixture_rig {
    void *opaque;
    const char *url; /* http://127.0.0.1:<ephemeral-port>/finite */
    int (*serve_two)(void *, const char *original, const char *prefix);
    int (*finish)(void *); /* join, verify two wire requests and socket closes */
};

int vortx_reference_fixture_run_case(struct vortx_reference_fixture_rig *, unsigned);

struct vortx_reference_fixture_case {
    const char *name;
    const char *prefix;
    int open_ok;
    int terminal;
    int complete;
    unsigned bytes;
    const char *original; /* NULL selects the ordinary known-eight-byte entity */
    int original_known;
    uint64_t original_total;
};

static const struct vortx_reference_fixture_case finite_cases[] = {
    { "complete-200", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Encoding: identity\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8 },
    { "complete-206", "HTTP/1.1 206 Partial Content\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Range: bytes 0-7/8\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8 },
    { "range-is-not-entity-eof", "HTTP/1.1 206 Partial Content\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n"
      "Content-Range: bytes 0-7/100\r\n\r\n12345678",
      1, AVERROR(ENOBUFS), 0, 8,
      "HTTP/1.1 206 Partial Content\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Range: bytes 0-7/100\r\n\r\n12345678", 1, 100 },
    { "short-body", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\n\r\n1234", 1, AVERROR_INVALIDDATA, 1, 4 },
    { "validator-changed", "HTTP/1.1 200 OK\r\nETag: \"fixture-v2\"\r\n"
      "Content-Length: 8\r\n\r\n12345678", 0 },
    { "duplicate-length", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Length: 8\r\n\r\n12345678", 0 },
    { "length-sign", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: +8\r\n\r\n12345678", 0 },
    { "range-junk", "HTTP/1.1 206 Partial Content\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Range: bytes 0-7/100junk\r\n\r\n12345678", 0 },
    { "range-unknown-total", "HTTP/1.1 206 Partial Content\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n"
      "Content-Range: bytes 0-7/*\r\n\r\n12345678", 0 },
    { "nonzero-range", "HTTP/1.1 206 Partial Content\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Range: bytes 1-8/100\r\n\r\n12345678", 0 },
    { "transfer-encoding", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nTransfer-Encoding: identity\r\n\r\n12345678", 0 },
    { "unknown-encoding", "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Encoding: br\r\n\r\n12345678", 0 },
    { "redirect", "HTTP/1.1 302 Found\r\nETag: \"fixture-v1\"\r\n"
      "Location: /different\r\nContent-Length: 0\r\n\r\n", 0 },
    { "bare-lf", "HTTP/1.1 200 OK\nETag: \"fixture-v1\"\n"
      "Content-Length: 8\n\n12345678", 0 },
    { "same-validator-changed-total-200", "HTTP/1.1 200 OK\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 4\r\n\r\n1234", 0 },
    { "same-validator-changed-total-206", "HTTP/1.1 206 Partial Content\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 4\r\n"
      "Content-Range: bytes 0-3/4\r\n\r\n1234", 0 },
    { "same-total-short-prefix-remains-partial", "HTTP/1.1 206 Partial Content\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 4\r\n"
      "Content-Range: bytes 0-3/8\r\n\r\n1234", 1, AVERROR(ENOBUFS), 0, 4 },
    { "original-chunked-total-unavailable", "HTTP/1.1 200 OK\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8,
      "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Transfer-Encoding: chunked\r\n\r\n8\r\n12345678\r\n0\r\n\r\n", 0, 0 },
    { "original-close-framing-total-unavailable", "HTTP/1.1 200 OK\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8,
      "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\nConnection: close\r\n\r\n12345678", 0, 0 },
    { "original-duplicate-length-unavailable", "HTTP/1.1 200 OK\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8,
      "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 8\r\nContent-Length: 8\r\n\r\n12345678", 0, 0 },
    { "original-overflow-length-unavailable", "HTTP/1.1 200 OK\r\n"
      "ETag: \"fixture-v1\"\r\nContent-Length: 8\r\n\r\n12345678",
      1, AVERROR_EOF, 1, 8,
      "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
      "Content-Length: 18446744073709551615\r\n\r\n12345678", 0, 0 },
};

unsigned genuine_http_case_count(void)
{
    return FF_ARRAY_ELEMS(finite_cases);
}

static int finite_fixture_interrupt(void *opaque)
{
    return *(const int *)opaque;
}

/* Calls the same private header reconstruction used by real capture, with
 * a genuine successfully sent snapshot from the real original HTTP owner. */
static int finite_fixture_options(
    const struct avpriv_vortx_http_sent_request *sent, AVDictionary **out)
{
    static const struct { const char *key, *value; } values[] = {
        {"method", "GET"}, {"tls_verify", "1"}, {"http_proxy", ""},
        {"cookies", ""}, {"icy", "0"}, {"seekable", "0"}, {"offset", "0"},
        {"end_offset", "64"}, {"multiple_requests", "0"}, {"reconnect", "0"},
        {"reconnect_at_eof", "0"}, {"reconnect_on_network_error", "0"},
        {"reconnect_on_http_error", ""}, {"reconnect_streamed", "0"},
        {"max_redirects", "0"}, {"timeout", "30000000"},
        {"rw_timeout", "30000000"}, {"protocol_whitelist", "http,tcp"},
    };
    char *headers = http_reference_prepared_headers(sent, "\"fixture-v1\"", 64);
    int ret = headers ? av_dict_set(out, "headers", headers, 0) : AVERROR(ENOMEM);
    av_free(headers);
    for (unsigned n = 0; ret >= 0 && n < FF_ARRAY_ELEMS(values); n++)
        ret = av_dict_set(out, values[n].key, values[n].value, 0);
    return ret;
}

int vortx_reference_fixture_run_case(struct vortx_reference_fixture_rig *rig,
                                    unsigned case_index)
{
    static const char original[] = "HTTP/1.1 200 OK\r\nETag: \"fixture-v1\"\r\n"
                                   "Content-Length: 8\r\n\r\n12345678";
    const struct vortx_reference_fixture_case *test;
    struct avpriv_vortx_http_sent_request sent = {0};
    struct avpriv_vortx_reference_recipe *recipe = NULL;
    struct avpriv_vortx_reference_reader *reader = NULL;
    struct avpriv_vortx_reference_stats stats = {0};
    struct HTTPReferenceLifetime *worker_ref = NULL;
    AVDictionary *original_options = NULL, *options = NULL;
    AVIOContext *owner = NULL;
    int cancelled = 0, ret = AVERROR(EINVAL);
    int64_t generation = 0;
    AVIOInterruptCB interrupt = {finite_fixture_interrupt, &cancelled};
    unsigned char buffer[3]; /* deliberate incremental read, never max size */
    volatile unsigned assertion_canary = 0;
    assert(++assertion_canary == 1);
    if (assertion_canary != 1)
        return AVERROR_BUG; /* Non-assert failure if assert ever stops executing. */
    assert(rig && case_index < FF_ARRAY_ELEMS(finite_cases));
    assert(rig->url && !strncmp(rig->url, "http://127.0.0.1:", 17));
    test = &finite_cases[case_index];
    if ((ret = rig->serve_two(rig->opaque, test->original ? test->original : original,
                               test->prefix)) < 0)
        goto done;
    if ((ret = av_dict_set(&original_options, "http_proxy", "", 0)) < 0 ||
        (ret = av_dict_set(&original_options, "protocol_whitelist", "http,tcp", 0)) < 0 ||
        (ret = av_dict_set(&original_options, "headers", "Accept-Encoding: identity\r\n", 0)) < 0 ||
        (ret = avio_open2(&owner, rig->url, AVIO_FLAG_READ, &interrupt,
                          &original_options)) < 0 ||
        (ret = av_opt_get_int(owner, "response_generation", AV_OPT_SEARCH_CHILDREN,
                              &generation)) < 0 ||
        (ret = avpriv_vortx_http_copy_sent_request_v2(owner, generation, &sent)) < 0 ||
        (ret = finite_fixture_options(&sent, &options)) < 0)
        goto done;
    /* Wrong-size calls must fail before touching even a non-structure input. */
    assert(avpriv_vortx_reference_capture_v1(owner, (const void *)buffer, 1,
             "\"fixture-v1\"", rig->url, options, 64, 30000000, &recipe) < 0);
    assert(!recipe);
    if ((ret = avpriv_vortx_reference_capture_v1(owner, &sent, sizeof(sent),
                "\"fixture-v1\"", rig->url, options, 64, 30000000, &recipe)) < 0)
        goto done;
    assert(recipe->pin.entity_total_known == (test->original ? test->original_known : 1));
    assert(recipe->pin.entity_total == (test->original ? test->original_total : 8));
    assert(avpriv_vortx_reference_recipe_current(recipe) == 1);
    ret = avpriv_vortx_reference_open_prefix_v1(recipe, &interrupt, &reader);
    assert((ret >= 0) == test->open_ok);
    if (ret < 0) {
        assert(!reader);
        ret = 0;
        goto revalidate;
    }
    do {
        ret = avpriv_vortx_reference_read_v1(reader, buffer, sizeof(buffer));
    } while (ret > 0);
    assert(ret == test->terminal);
    assert(avpriv_vortx_reference_stats_v1(reader, &stats, sizeof(stats)) == 0);
    assert(stats.body_bytes == test->bytes && stats.max_bytes == 64);
    assert(stats.complete_entity == test->complete);
    assert(stats.reached_entity_eof == (ret == AVERROR_EOF));
    assert(stats.terminal_error == (ret == AVERROR_EOF ? 0 : ret));
    assert(avpriv_vortx_reference_stats_v1(reader, (void *)buffer, 1) < 0);
    avpriv_vortx_reference_reader_close_v1(&reader);
    ret = 0;
revalidate:
    /* Closing the duplicate must leave the genuine original owner untouched. */
    assert(avpriv_vortx_reference_revalidate_v1(owner, &sent, sizeof(sent), recipe) == 0);
done:
    avpriv_vortx_reference_reader_close_v1(&reader);
    if (recipe && owner) {
        worker_ref = http_reference_lifetime_retain(recipe->lifetime);
        assert(worker_ref);
        avio_closep(&owner); /* actual original transport close retires first */
        assert(avpriv_vortx_reference_recipe_current(recipe) == 0);
    }
    avpriv_vortx_reference_recipe_release_v1(&recipe);
#if VORTX_REFERENCE_LIFETIME_ATOMICS
    if (worker_ref) {
        /* Parent/HTTP and recipe refs are gone; final worker ref stays safe. */
        assert(atomic_load_explicit(&worker_ref->retired, memory_order_acquire));
        assert(atomic_load_explicit(&worker_ref->references, memory_order_acquire) == 1);
    }
#endif
    http_reference_lifetime_drop(worker_ref); /* final free, never dereference again */
    avpriv_vortx_http_sent_request_clear_v2(&sent);
    av_dict_free(&options);
    av_dict_free(&original_options);
    avio_closep(&owner);
    if (rig->finish(rig->opaque) < 0)
        ret = AVERROR_INVALIDDATA;
    return ret;
}

/* Additional causal fixture seam after a REAL owner/recipe capture. For
 * reconnect, the delegated loopback rig must serve the third request. The
 * getter must observe retirement even if that new open fails or the same
 * ETag/URL/total is returned. No fake response token/state is manufactured. */
int vortx_reference_fixture_lifetime_action(
    AVIOContext *owner, struct avpriv_vortx_reference_recipe *recipe,
    int reconnect, const char *same_url)
{
    URLContext *h = ffio_geturlcontext(owner);
    HTTPContext *s;
    int ret = 0;
    assert(h && recipe && avpriv_vortx_reference_recipe_current(recipe));
    s = h->priv_data;
    assert(s->reference_lifetime == recipe->lifetime);
    if (reconnect)
        ret = ff_http_do_new_request(h, same_url); /* genuine HTTP request path */
    else
        http_response_etag_reset_request(s); /* actual reset helper seam */
    assert(!avpriv_vortx_reference_recipe_current(recipe));
    return ret;
}

/* Current publication lifetime has no work-deadline expiry. Invoke only after
 * reader close on a genuine retained recipe, while the original owner lives. */
void vortx_reference_fixture_lifetime_has_no_work_expiry(
    struct avpriv_vortx_reference_recipe *recipe)
{
    assert(avpriv_vortx_reference_recipe_current(recipe));
    recipe->deadline_us = 0;
    assert(avpriv_vortx_reference_recipe_current(recipe));
}
