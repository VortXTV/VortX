/*
 * Strict v2 capture fixture. It returns only owned scalar node maps and the
 * exact hidden-reference snapshot required by the maintained afterimage. It
 * never opens media, parses a container, or links a player/native library.
 */
#include "MPVCaptureFixture.h"
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum {
    VORTX_CAPTURE_VALID = 0,
    VORTX_CAPTURE_OLD_MISSING_PROPERTY = 1,
    VORTX_CAPTURE_WRONG_SCHEMA_4 = 2,
    VORTX_CAPTURE_WRONG_SCHEMA_6 = 3,
    VORTX_CAPTURE_DUPLICATE_KEY = 4,
    VORTX_CAPTURE_UNKNOWN_KEY = 5,
    VORTX_CAPTURE_NUMERIC_BOOLEAN = 6,
    VORTX_CAPTURE_OSC_FALSE = 7,
    VORTX_CAPTURE_MALFORMED_IDENTITY = 8,
    VORTX_CAPTURE_NS_BOUNDS = 9,
    VORTX_CAPTURE_SOURCE_GENERATION_CHANGED = 10,
    VORTX_CAPTURE_ENTRY_CHANGED = 11,
    VORTX_CAPTURE_SID_CHANGED = 12,
    VORTX_CAPTURE_INVALID_TIMING = 13,
    VORTX_CAPTURE_CUSTOM_INPUT = 14,
    VORTX_CAPTURE_REMOTE_INPUT = 15,
    VORTX_CAPTURE_BUILTIN_MKV = 16,
    VORTX_CAPTURE_EXTERNAL_TRACK = 17,
    VORTX_CAPTURE_DUPLICATE_SELECTED = 18,
    VORTX_CAPTURE_FF_INDEX_RANGE = 19,
    VORTX_CAPTURE_NIL_PROPERTY = 20,
    VORTX_CAPTURE_SNAPSHOT_WRONG_VERSION = 21,
    VORTX_CAPTURE_SNAPSHOT_MISSING_FIELD = 22,
    VORTX_CAPTURE_HIDDEN_EXTERNAL_PRIMARY = 23,
    VORTX_CAPTURE_TRACK_LIST_COMMAND_MISMATCH = 24,
    VORTX_CAPTURE_SNAPSHOT_STREAM_MISMATCH = 25,
    VORTX_CAPTURE_SNAPSHOT_OFF_EXTERNAL = 26
};

static const uint64_t STRING_MAGIC = UINT64_C(0x5652545853563231);
static const uint64_t LIST_MAGIC = UINT64_C(0x565254584c563231);
typedef struct fixture fixture;
typedef struct owned_string { fixture *owner; uint64_t magic; char bytes[]; } owned_string;
typedef struct owned_list { fixture *owner; uint64_t magic; mpv_node_list list; } owned_list;
struct fixture {
    int scenario;
    uint64_t metadata_reads;
    uint64_t snapshot_reads;
    uint64_t node_allocations, node_frees, string_allocations, string_frees;
};

static fixture *from_handle(mpv_handle *handle) { return (fixture *)(void *)handle; }
static const fixture *from_const_handle(const mpv_handle *handle) { return (const fixture *)(const void *)handle; }
static char *owned_text(fixture *f, const char *value) {
    if (!f || !value) return NULL;
    size_t n = strlen(value); owned_string *box = malloc(sizeof(*box) + n + 1);
    if (!box) return NULL; box->owner = f; box->magic = STRING_MAGIC;
    memcpy(box->bytes, value, n + 1); f->string_allocations++; return box->bytes;
}
static owned_string *string_box(char *value) {
    return value ? (owned_string *)((char *)value - offsetof(owned_string, bytes)) : NULL;
}
static void release_text(char *value) {
    owned_string *box = string_box(value);
    if (!box || box->magic != STRING_MAGIC) return;
    box->magic = 0; box->owner->string_frees++; free(box);
}
static owned_list *list_box(mpv_node_list *list) {
    return list ? (owned_list *)((char *)list - offsetof(owned_list, list)) : NULL;
}
static void release_list(mpv_node_list *list) {
    owned_list *box = list_box(list);
    if (!box || box->magic != LIST_MAGIC) return;
    for (int i = 0; i < list->num; ++i) {
        release_text(list->keys ? list->keys[i] : NULL);
        if (list->values && list->values[i].format == MPV_FORMAT_STRING)
            release_text(list->values[i].u.string);
    }
    free(list->keys); free(list->values); box->magic = 0;
    box->owner->node_frees++; free(box);
}
static int key(fixture *f, mpv_node_list *list, int i, const char *name) {
    list->keys[i] = owned_text(f, name); return list->keys[i] ? 0 : -1;
}
static void integer(mpv_node *value, int64_t n) { value->format = MPV_FORMAT_INT64; value->u.int64 = n; }
static void number(mpv_node *value, double n) { value->format = MPV_FORMAT_DOUBLE; value->u.double_ = n; }
static void flag(mpv_node *value, int n) { value->format = MPV_FORMAT_FLAG; value->u.flag = n ? 1 : 0; }
static int string_value(fixture *f, mpv_node *value, const char *text) {
    value->format = MPV_FORMAT_STRING; value->u.string = owned_text(f, text); return value->u.string ? 0 : -1;
}
static int make_map(fixture *f, mpv_node *node, int count, const char *const *names) {
    owned_list *box = calloc(1, sizeof(*box)); if (!box) return -1;
    box->owner = f; box->magic = LIST_MAGIC; box->list.num = count;
    box->list.keys = calloc((size_t)count, sizeof(*box->list.keys));
    box->list.values = calloc((size_t)count, sizeof(*box->list.values));
    if (!box->list.keys || !box->list.values) { release_list(&box->list); return -1; }
    for (int i = 0; i < count; ++i) if (key(f, &box->list, i, names[i]) < 0) { release_list(&box->list); return -1; }
    memset(node, 0, sizeof(*node)); node->format = MPV_FORMAT_NODE_MAP; node->u.list = &box->list; f->node_allocations++; return 0;
}
static const char *identity(const fixture *f) {
    if (f->scenario == VORTX_CAPTURE_MALFORMED_IDENTITY) return "12:987654:0:1700000000:123456789:1700000001:987654321";
    if (f->scenario == VORTX_CAPTURE_NS_BOUNDS) return "12:987654:123456:1700000000:1000000000:1700000001:987654321";
    return "12:987654:123456:1700000000:123456789:1700000001:987654321";
}
static int64_t metadata_entry(const fixture *f) { return f->scenario == VORTX_CAPTURE_ENTRY_CHANGED && f->metadata_reads >= 2 ? 42 : 41; }
static int64_t metadata_generation(const fixture *f) { return f->scenario == VORTX_CAPTURE_SOURCE_GENERATION_CHANGED && f->metadata_reads >= 2 ? 8 : 7; }
static int make_metadata(fixture *f, mpv_node *node) {
    static const char *valid[] = { "identity", "version", "osc-disabled", "entry-id", "source-generation" };
    static const char *four[] = { "identity", "version", "entry-id", "source-generation" };
    static const char *six[] = { "identity", "version", "osc-disabled", "entry-id", "source-generation", "future-key" };
    static const char *duplicate[] = { "identity", "version", "osc-disabled", "entry-id", "identity" };
    static const char *unknown[] = { "identity", "version", "osc-disabled", "entry-id", "future-key" };
    int count = 5; const char *const *names = valid;
    if (f->scenario == VORTX_CAPTURE_WRONG_SCHEMA_4) { count = 4; names = four; }
    else if (f->scenario == VORTX_CAPTURE_WRONG_SCHEMA_6) { count = 6; names = six; }
    else if (f->scenario == VORTX_CAPTURE_DUPLICATE_KEY) names = duplicate;
    else if (f->scenario == VORTX_CAPTURE_UNKNOWN_KEY) names = unknown;
    if (make_map(f, node, count, names) < 0) return -1;
    mpv_node_list *list = node->u.list;
    for (int i = 0; i < count; ++i) {
        const char *name = names[i]; mpv_node *value = &list->values[i];
        if (!strcmp(name, "identity")) { if (string_value(f, value, identity(f)) < 0) return -1; }
        else if (!strcmp(name, "version")) integer(value, 1);
        else if (!strcmp(name, "osc-disabled")) {
            if (f->scenario == VORTX_CAPTURE_NUMERIC_BOOLEAN) integer(value, 1); else flag(value, f->scenario != VORTX_CAPTURE_OSC_FALSE);
        } else if (!strcmp(name, "entry-id")) integer(value, metadata_entry(f));
        else if (!strcmp(name, "source-generation")) integer(value, metadata_generation(f));
        else integer(value, 99);
    }
    return 0;
}
static int make_snapshot(fixture *f, mpv_node *node) {
    static const char *names[] = { "version", "intent-generation", "entry-id", "source-generation", "reference-sid", "reference-command-index", "reference-stream-index", "demux-origin", "primary-sid", "primary-external", "primary-visible", "active-ticket" };
    int count = 12; if (f->scenario == VORTX_CAPTURE_SNAPSHOT_MISSING_FIELD) count = 11;
    if (make_map(f, node, count, names) < 0) return -1;
    mpv_node_list *list = node->u.list;
    integer(&list->values[0], f->scenario == VORTX_CAPTURE_SNAPSHOT_WRONG_VERSION ? 1 : 2);
    integer(&list->values[1], 8); integer(&list->values[2], 41); integer(&list->values[3], 7);
    integer(&list->values[4], f->scenario == VORTX_CAPTURE_SID_CHANGED && f->snapshot_reads >= 2 ? 13 : 12);
    integer(&list->values[5], 17);
    integer(&list->values[6], f->scenario == VORTX_CAPTURE_SNAPSHOT_STREAM_MISMATCH && f->snapshot_reads >= 2 ? 36 : 37); number(&list->values[7], 100.0);
    const int offExternal = f->scenario == VORTX_CAPTURE_SNAPSHOT_OFF_EXTERNAL;
    const int external = f->scenario == VORTX_CAPTURE_HIDDEN_EXTERNAL_PRIMARY || offExternal;
    integer(&list->values[8], offExternal ? 0 : (external ? 77 : 0)); flag(&list->values[9], external); flag(&list->values[10], 0);
    if (count == 12) integer(&list->values[11], 0);
    return 0;
}
static const char *track_type(const fixture *f, int row) {
    if (row == 0) return "audio";
    if (row == 1) return "sub";
    if (row == 2 && f->scenario == VORTX_CAPTURE_DUPLICATE_SELECTED) return "sub";
    return row == 2 ? "video" : NULL;
}
static int parse_track(const char *name, int *row, const char **field) {
    if (strncmp(name, "track-list/", 11) != 0) return 0; char *end = NULL; long n = strtol(name + 11, &end, 10);
    if (end == name + 11 || n < 0 || n > 127 || *end != '/') return 0; *row = (int)n; *field = end + 1; return 1;
}

mpv_handle *vortx_capture_fixture_v2_create(int scenario) { fixture *f = calloc(1, sizeof(*f)); if (!f) return NULL; f->scenario = scenario; return (mpv_handle *)(void *)f; }
void vortx_capture_fixture_v2_destroy(mpv_handle *handle) { free(from_handle(handle)); }
uint64_t vortx_capture_fixture_v2_node_allocations(const mpv_handle *h) { const fixture *f = from_const_handle(h); return f ? f->node_allocations : 0; }
uint64_t vortx_capture_fixture_v2_node_frees(const mpv_handle *h) { const fixture *f = from_const_handle(h); return f ? f->node_frees : 0; }
uint64_t vortx_capture_fixture_v2_string_allocations(const mpv_handle *h) { const fixture *f = from_const_handle(h); return f ? f->string_allocations : 0; }
uint64_t vortx_capture_fixture_v2_string_frees(const mpv_handle *h) { const fixture *f = from_const_handle(h); return f ? f->string_frees : 0; }
int vortx_capture_fixture_v2_allocations_balanced(const mpv_handle *h) { const fixture *f = from_const_handle(h); return f && f->node_allocations == f->node_frees && f->string_allocations == f->string_frees; }

MPV_EXPORT int mpv_get_property(mpv_handle *handle, const char *name, mpv_format format, void *data) {
    fixture *f = from_handle(handle); if (!f || !name || !data) return MPV_ERROR_INVALID_PARAMETER;
    if (!strcmp(name, "vortx-original-local-file")) { if (format != MPV_FORMAT_NODE || f->scenario == VORTX_CAPTURE_OLD_MISSING_PROPERTY) return MPV_ERROR_PROPERTY_NOT_FOUND; f->metadata_reads++; return make_metadata(f, data) < 0 ? MPV_ERROR_NOMEM : 0; }
    if (!strcmp(name, "vortx-owned-subtitle-state")) {
        if (format != MPV_FORMAT_NODE) return MPV_ERROR_PROPERTY_FORMAT;
        f->snapshot_reads++;
        return make_snapshot(f, data) < 0 ? MPV_ERROR_NOMEM : 0;
    }
    if (format == MPV_FORMAT_INT64) {
        int64_t *out = data; int row = 0; const char *field = NULL;
        if (!strcmp(name, "track-list/count")) { *out = 3; return 0; }
        if (!strcmp(name, "sid")) { *out = 12; return 0; }
        if (!strcmp(name, "track-list/1/id")) { *out = 12; return 0; }
        if (!strcmp(name, "track-list/1/ff-index")) {
            if (f->scenario == VORTX_CAPTURE_FF_INDEX_RANGE) { *out = 128; return 0; }
            *out = f->scenario == VORTX_CAPTURE_TRACK_LIST_COMMAND_MISMATCH ? 16 : 17;
            return 0;
        }
        if (parse_track(name, &row, &field) && (!strcmp(field, "id") || !strcmp(field, "ff-index") || !strcmp(field, "main-selection"))) {
            if (!strcmp(field, "id")) {
                *out = row == 1 ? 12 : row == 0 ? 2 : (f->scenario == VORTX_CAPTURE_DUPLICATE_SELECTED ? 12 : 88);
            } else if (!strcmp(field, "ff-index")) {
                if (row == 2 && f->scenario == VORTX_CAPTURE_DUPLICATE_SELECTED) {
                    *out = 17; // Same genuine mapping; only duplicate reference identity must deny it.
                } else {
                    *out = row == 1 ? (f->scenario == VORTX_CAPTURE_FF_INDEX_RANGE ? 128 : (f->scenario == VORTX_CAPTURE_TRACK_LIST_COMMAND_MISMATCH ? 16 : 17)) : 88;
                }
            } else {
                // The hidden reference is not the visible primary. Keep the
                // old visible-selection witness unavailable so a regression
                // that requires selected/main-selection cannot pass this case.
                *out = -1;
            }
            return 0;
        }
        return MPV_ERROR_PROPERTY_NOT_FOUND;
    }
    if (format == MPV_FORMAT_FLAG) {
        int *out = data; int row = 0; const char *field = NULL;
        if (!strcmp(name, "input-terminal") || !strcmp(name, "input-default-bindings") || !strcmp(name, "input-vo-keyboard")) { *out = 0; return 0; }
        if (!strcmp(name, "options/rebase-start-time")) { *out = 1; return 0; }
        if (parse_track(name, &row, &field) && !strcmp(field, "external")) { *out = row == 1 && f->scenario == VORTX_CAPTURE_EXTERNAL_TRACK; return 0; }
        if (parse_track(name, &row, &field) && !strcmp(field, "selected")) {
            *out = 0; return 0;
        }
        return MPV_ERROR_PROPERTY_NOT_FOUND;
    }
    if (format == MPV_FORMAT_DOUBLE) {
        double *out = data;
        if (!strcmp(name, "demuxer-start-time")) { *out = f->scenario == VORTX_CAPTURE_INVALID_TIMING ? 86400.5 : 100.0; return 0; }
        if (!strcmp(name, "sub-delay")) { *out = 0; return 0; }
        if (!strcmp(name, "sub-speed")) { *out = 1; return 0; }
        if (!strcmp(name, "sub-fps")) { *out = 0; return 0; }
    }
    return MPV_ERROR_PROPERTY_NOT_FOUND;
}
MPV_EXPORT char *mpv_get_property_string(mpv_handle *handle, const char *name) {
    fixture *f = from_handle(handle); if (!f || !name) return NULL;
    if (!strcmp(name, "current-demuxer")) return owned_text(f, f->scenario == VORTX_CAPTURE_BUILTIN_MKV ? "mkv" : "lavf");
    if (!strcmp(name, "stream-path")) {
        if (f->scenario == VORTX_CAPTURE_CUSTOM_INPUT) return owned_text(f, "custom://generated-subtitle-source");
        if (f->scenario == VORTX_CAPTURE_REMOTE_INPUT) return owned_text(f, "https://cdn.example.invalid/media.mkv");
        if (f->scenario == VORTX_CAPTURE_NIL_PROPERTY) return NULL; return owned_text(f, "/private/var/tmp/vortx-capture-local.mkv");
    }
    int row = 0; const char *field = NULL; if (parse_track(name, &row, &field) && !strcmp(field, "type")) return owned_text(f, track_type(f, row));
    return NULL;
}
MPV_EXPORT void mpv_free(void *data) { release_text((char *)data); }
MPV_EXPORT void mpv_free_node_contents(mpv_node *node) { if (!node) return; if (node->format == MPV_FORMAT_NODE_MAP || node->format == MPV_FORMAT_NODE_ARRAY) release_list(node->u.list); node->format = MPV_FORMAT_NONE; node->u.list = NULL; }
