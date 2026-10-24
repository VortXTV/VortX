/*
 * Controlled mpv C test fixture.
 *
 * This file deliberately implements only the four libmpv calls used by the
 * actual capture source: node property read, string property read, and the
 * two documented release functions.  It never opens media, starts a player,
 * parses a container, or links libmpv.  Every API-owned node/string has an
 * owner header so the Swift entry can prove that all returned allocations are
 * released on success and every refusal path.
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
    VORTX_CAPTURE_NIL_PROPERTY = 20
};

static const uint64_t VORTX_CAPTURE_STRING_MAGIC = UINT64_C(0x5652545853545231);
static const uint64_t VORTX_CAPTURE_LIST_MAGIC = UINT64_C(0x565254584c535431);

typedef struct vortx_capture_fixture vortx_capture_fixture;

typedef struct vortx_capture_owned_string {
    vortx_capture_fixture *owner;
    uint64_t magic;
    char bytes[];
} vortx_capture_owned_string;

typedef struct vortx_capture_owned_list {
    vortx_capture_fixture *owner;
    uint64_t magic;
    mpv_node_list list;
} vortx_capture_owned_list;

struct vortx_capture_fixture {
    int scenario;
    uint64_t metadata_reads;
    uint64_t sid_reads;
    uint64_t node_allocations;
    uint64_t node_frees;
    uint64_t string_allocations;
    uint64_t string_frees;
};

static vortx_capture_fixture *fixture_from_handle(mpv_handle *handle)
{
    return (vortx_capture_fixture *)(void *)handle;
}

static const vortx_capture_fixture *fixture_from_const_handle(const mpv_handle *handle)
{
    return (const vortx_capture_fixture *)(const void *)handle;
}

static char *owned_string(vortx_capture_fixture *fixture, const char *value)
{
    if (!fixture || !value)
        return NULL;
    size_t length = strlen(value);
    vortx_capture_owned_string *box = malloc(sizeof(*box) + length + 1);
    if (!box)
        return NULL;
    box->owner = fixture;
    box->magic = VORTX_CAPTURE_STRING_MAGIC;
    memcpy(box->bytes, value, length + 1);
    fixture->string_allocations++;
    return box->bytes;
}

static vortx_capture_owned_string *owned_string_box(char *value)
{
    if (!value)
        return NULL;
    return (vortx_capture_owned_string *)((char *)value - offsetof(vortx_capture_owned_string, bytes));
}

static void release_owned_string(char *value)
{
    vortx_capture_owned_string *box = owned_string_box(value);
    if (!box || box->magic != VORTX_CAPTURE_STRING_MAGIC)
        return;
    box->magic = 0;
    box->owner->string_frees++;
    free(box);
}

static vortx_capture_owned_list *owned_list_box(mpv_node_list *list)
{
    if (!list)
        return NULL;
    return (vortx_capture_owned_list *)((char *)list - offsetof(vortx_capture_owned_list, list));
}

static void release_node_payload(mpv_node_list *list)
{
    vortx_capture_owned_list *box = owned_list_box(list);
    if (!box || box->magic != VORTX_CAPTURE_LIST_MAGIC)
        return;
    for (int i = 0; i < list->num; ++i) {
        release_owned_string(list->keys ? list->keys[i] : NULL);
        if (list->values && list->values[i].format == MPV_FORMAT_STRING)
            release_owned_string(list->values[i].u.string);
    }
    free(list->keys);
    free(list->values);
    box->magic = 0;
    box->owner->node_frees++;
    free(box);
}

static int set_key(vortx_capture_fixture *fixture, mpv_node_list *list, int index, const char *key)
{
    list->keys[index] = owned_string(fixture, key);
    return list->keys[index] ? 0 : -1;
}

static int set_string(vortx_capture_fixture *fixture, mpv_node *value, const char *text)
{
    value->format = MPV_FORMAT_STRING;
    value->u.string = owned_string(fixture, text);
    return value->u.string ? 0 : -1;
}

static void set_int64(mpv_node *value, int64_t number)
{
    value->format = MPV_FORMAT_INT64;
    value->u.int64 = number;
}

static void set_flag(mpv_node *value, int flag)
{
    value->format = MPV_FORMAT_FLAG;
    value->u.flag = flag;
}

static int map_count_for_scenario(int scenario)
{
    if (scenario == VORTX_CAPTURE_WRONG_SCHEMA_4)
        return 4;
    if (scenario == VORTX_CAPTURE_WRONG_SCHEMA_6)
        return 6;
    return 5;
}

static const char *identity_for_scenario(int scenario)
{
    if (scenario == VORTX_CAPTURE_MALFORMED_IDENTITY)
        return "12:987654:0:1700000000:123456789:1700000001:987654321";
    if (scenario == VORTX_CAPTURE_NS_BOUNDS)
        return "12:987654:123456:1700000000:1000000000:1700000001:987654321";
    return "12:987654:123456:1700000000:123456789:1700000001:987654321";
}

static int64_t entry_for_metadata(const vortx_capture_fixture *fixture)
{
    if (fixture->scenario == VORTX_CAPTURE_ENTRY_CHANGED && fixture->metadata_reads >= 2)
        return 42;
    return 41;
}

static int64_t generation_for_metadata(const vortx_capture_fixture *fixture)
{
    if (fixture->scenario == VORTX_CAPTURE_SOURCE_GENERATION_CHANGED && fixture->metadata_reads >= 2)
        return 8;
    return 7;
}

static int metadata_key_and_value(vortx_capture_fixture *fixture,
                                  mpv_node_list *list, int index, const char *key)
{
    if (set_key(fixture, list, index, key) < 0)
        return -1;

    mpv_node *value = &list->values[index];
    if (!strcmp(key, "version")) {
        set_int64(value, 1);
        return 0;
    }
    if (!strcmp(key, "entry-id")) {
        set_int64(value, entry_for_metadata(fixture));
        return 0;
    }
    if (!strcmp(key, "source-generation")) {
        set_int64(value, generation_for_metadata(fixture));
        return 0;
    }
    if (!strcmp(key, "identity"))
        return set_string(fixture, value, identity_for_scenario(fixture->scenario));
    if (!strcmp(key, "osc-disabled")) {
        if (fixture->scenario == VORTX_CAPTURE_NUMERIC_BOOLEAN)
            set_int64(value, 1);
        else
            set_flag(value, fixture->scenario == VORTX_CAPTURE_OSC_FALSE ? 0 : 1);
        return 0;
    }
    if (!strcmp(key, "future-key")) {
        set_int64(value, 99);
        return 0;
    }
    set_int64(value, 99);
    return 0;
}

static int make_metadata(vortx_capture_fixture *fixture, mpv_node *node)
{
    static const char *valid_keys[] = {
        "identity", "version", "osc-disabled", "entry-id", "source-generation"
    };
    static const char *wrong_four_keys[] = {
        "identity", "version", "entry-id", "source-generation"
    };
    static const char *wrong_six_keys[] = {
        "identity", "version", "osc-disabled", "entry-id", "source-generation", "future-key"
    };
    static const char *duplicate_keys[] = {
        "identity", "version", "osc-disabled", "entry-id", "identity"
    };
    static const char *unknown_keys[] = {
        "identity", "version", "osc-disabled", "entry-id", "future-key"
    };

    int count = map_count_for_scenario(fixture->scenario);
    const char *const *keys = valid_keys;
    if (fixture->scenario == VORTX_CAPTURE_WRONG_SCHEMA_4)
        keys = wrong_four_keys;
    else if (fixture->scenario == VORTX_CAPTURE_WRONG_SCHEMA_6)
        keys = wrong_six_keys;
    else if (fixture->scenario == VORTX_CAPTURE_DUPLICATE_KEY)
        keys = duplicate_keys;
    else if (fixture->scenario == VORTX_CAPTURE_UNKNOWN_KEY)
        keys = unknown_keys;

    vortx_capture_owned_list *box = calloc(1, sizeof(*box));
    if (!box)
        return -1;
    box->owner = fixture;
    box->magic = VORTX_CAPTURE_LIST_MAGIC;
    box->list.num = count;
    box->list.keys = calloc((size_t)count, sizeof(*box->list.keys));
    box->list.values = calloc((size_t)count, sizeof(*box->list.values));
    if (!box->list.keys || !box->list.values) {
        release_node_payload(&box->list);
        return -1;
    }

    for (int i = 0; i < count; ++i) {
        if (metadata_key_and_value(fixture, &box->list, i, keys[i]) < 0) {
            release_node_payload(&box->list);
            return -1;
        }
    }
    memset(node, 0, sizeof(*node));
    node->format = MPV_FORMAT_NODE_MAP;
    node->u.list = &box->list;
    fixture->node_allocations++;
    return 0;
}

static int parse_track_field(const char *name, int *row, const char **field)
{
    static const char prefix[] = "track-list/";
    if (!name || strncmp(name, prefix, sizeof(prefix) - 1))
        return 0;
    const char *cursor = name + sizeof(prefix) - 1;
    char *end = NULL;
    long parsed = strtol(cursor, &end, 10);
    if (end == cursor || parsed < 0 || parsed > 127 || *end != '/')
        return 0;
    const char *suffix = end + 1;
    if (!strcmp(suffix, "type") || !strcmp(suffix, "id") ||
        !strcmp(suffix, "external") || !strcmp(suffix, "selected") ||
        !strcmp(suffix, "main-selection") || !strcmp(suffix, "ff-index")) {
        *row = (int)parsed;
        *field = suffix;
        return 1;
    }
    return 0;
}

static const char *track_type_for_row(const vortx_capture_fixture *fixture, int row)
{
    if (row == 0)
        return "audio";
    if (row == 1 || (fixture->scenario == VORTX_CAPTURE_DUPLICATE_SELECTED && row == 2))
        return "sub";
    if (row == 2)
        return "video";
    return NULL;
}

static int track_flag_for_row(const vortx_capture_fixture *fixture, int row, const char *field)
{
    if (!strcmp(field, "external"))
        return row == 1 && fixture->scenario == VORTX_CAPTURE_EXTERNAL_TRACK;
    if (!strcmp(field, "selected"))
        return row == 1 || (fixture->scenario == VORTX_CAPTURE_DUPLICATE_SELECTED && row == 2);
    return 0;
}

static int64_t track_integer_for_row(const vortx_capture_fixture *fixture, int row, const char *field)
{
    if (!strcmp(field, "id"))
        return 1;
    if (!strcmp(field, "main-selection"))
        return 0;
    if (!strcmp(field, "ff-index")) {
        if (row == 1 && fixture->scenario == VORTX_CAPTURE_FF_INDEX_RANGE)
            return 128;
        if (row == 1)
            return 37;
        return row == 0 ? 2 : 88;
    }
    return 0;
}

static const char *string_property_value(const vortx_capture_fixture *fixture, const char *name)
{
    if (!strcmp(name, "current-demuxer")) {
        if (fixture->scenario == VORTX_CAPTURE_NIL_PROPERTY)
            return NULL;
        return fixture->scenario == VORTX_CAPTURE_BUILTIN_MKV ? "mkv" : "lavf";
    }
    if (!strcmp(name, "stream-path")) {
        if (fixture->scenario == VORTX_CAPTURE_NIL_PROPERTY)
            return NULL;
        if (fixture->scenario == VORTX_CAPTURE_CUSTOM_INPUT)
            return "custom://generated-subtitle-source";
        if (fixture->scenario == VORTX_CAPTURE_REMOTE_INPUT)
            return "https://cdn.example.invalid/media.mkv";
        return "/private/var/tmp/vortx-capture-local.mkv";
    }

    int row = 0;
    const char *field = NULL;
    if (parse_track_field(name, &row, &field) && !strcmp(field, "type"))
        return track_type_for_row(fixture, row);
    return NULL;
}

static int integer_property_value(vortx_capture_fixture *fixture, const char *name, int64_t *result)
{
    if (!strcmp(name, "sid")) {
        fixture->sid_reads++;
        *result = fixture->scenario == VORTX_CAPTURE_SID_CHANGED && fixture->sid_reads >= 2 ? 2 : 1;
        return 0;
    }
    if (!strcmp(name, "track-list/count")) {
        *result = 3;
        return 0;
    }

    int row = 0;
    const char *field = NULL;
    if (parse_track_field(name, &row, &field) &&
        (!strcmp(field, "id") || !strcmp(field, "main-selection") || !strcmp(field, "ff-index"))) {
        if (row < 0 || row > 2)
            return -1;
        *result = track_integer_for_row(fixture, row, field);
        return 0;
    }
    return -1;
}

static int flag_property_value(const vortx_capture_fixture *fixture, const char *name, int *result)
{
    if (!strcmp(name, "input-terminal") || !strcmp(name, "input-default-bindings") ||
        !strcmp(name, "input-vo-keyboard")) {
        *result = 0;
        return 0;
    }
    if (!strcmp(name, "options/rebase-start-time")) {
        *result = 1;
        return 0;
    }

    int row = 0;
    const char *field = NULL;
    if (parse_track_field(name, &row, &field) &&
        (!strcmp(field, "external") || !strcmp(field, "selected"))) {
        if (row < 0 || row > 2)
            return -1;
        *result = track_flag_for_row(fixture, row, field);
        return 0;
    }
    return -1;
}

static int double_property_value(const vortx_capture_fixture *fixture, const char *name, double *result)
{
    if (!strcmp(name, "demuxer-start-time")) {
        *result = fixture->scenario == VORTX_CAPTURE_INVALID_TIMING ? 86400.5 : 100.0;
        return 0;
    }
    if (!strcmp(name, "sub-delay")) {
        *result = 0.0;
        return 0;
    }
    if (!strcmp(name, "sub-speed")) {
        *result = 1.0;
        return 0;
    }
    if (!strcmp(name, "sub-fps")) {
        *result = 0.0;
        return 0;
    }
    return -1;
}

mpv_handle *vortx_capture_fixture_create(int scenario)
{
    vortx_capture_fixture *fixture = calloc(1, sizeof(*fixture));
    if (!fixture)
        return NULL;
    fixture->scenario = scenario;
    return (mpv_handle *)(void *)fixture;
}

void vortx_capture_fixture_destroy(mpv_handle *handle)
{
    free(fixture_from_handle(handle));
}

uint64_t vortx_capture_fixture_node_allocations(const mpv_handle *handle)
{
    const vortx_capture_fixture *fixture = fixture_from_const_handle(handle);
    return fixture ? fixture->node_allocations : 0;
}

uint64_t vortx_capture_fixture_node_frees(const mpv_handle *handle)
{
    const vortx_capture_fixture *fixture = fixture_from_const_handle(handle);
    return fixture ? fixture->node_frees : 0;
}

uint64_t vortx_capture_fixture_string_allocations(const mpv_handle *handle)
{
    const vortx_capture_fixture *fixture = fixture_from_const_handle(handle);
    return fixture ? fixture->string_allocations : 0;
}

uint64_t vortx_capture_fixture_string_frees(const mpv_handle *handle)
{
    const vortx_capture_fixture *fixture = fixture_from_const_handle(handle);
    return fixture ? fixture->string_frees : 0;
}

int vortx_capture_fixture_allocations_balanced(const mpv_handle *handle)
{
    const vortx_capture_fixture *fixture = fixture_from_const_handle(handle);
    return fixture && fixture->node_allocations == fixture->node_frees &&
           fixture->string_allocations == fixture->string_frees;
}

MPV_EXPORT int mpv_get_property(mpv_handle *handle, const char *name,
                                mpv_format format, void *data)
{
    vortx_capture_fixture *fixture = fixture_from_handle(handle);
    if (!fixture || !name || !data)
        return MPV_ERROR_INVALID_PARAMETER;

    if (!strcmp(name, "vortx-original-local-file")) {
        if (format != MPV_FORMAT_NODE)
            return MPV_ERROR_PROPERTY_FORMAT;
        if (fixture->scenario == VORTX_CAPTURE_OLD_MISSING_PROPERTY)
            return MPV_ERROR_PROPERTY_NOT_FOUND;
        fixture->metadata_reads++;
        return make_metadata(fixture, (mpv_node *)data) < 0 ? MPV_ERROR_NOMEM : 0;
    }
    if (format == MPV_FORMAT_INT64)
        return integer_property_value(fixture, name, (int64_t *)data) == 0 ? 0 : MPV_ERROR_PROPERTY_NOT_FOUND;
    if (format == MPV_FORMAT_FLAG)
        return flag_property_value(fixture, name, (int *)data) == 0 ? 0 : MPV_ERROR_PROPERTY_NOT_FOUND;
    if (format == MPV_FORMAT_DOUBLE)
        return double_property_value(fixture, name, (double *)data) == 0 ? 0 : MPV_ERROR_PROPERTY_NOT_FOUND;
    return MPV_ERROR_PROPERTY_FORMAT;
}

MPV_EXPORT char *mpv_get_property_string(mpv_handle *handle, const char *name)
{
    vortx_capture_fixture *fixture = fixture_from_handle(handle);
    if (!fixture || !name)
        return NULL;
    return owned_string(fixture, string_property_value(fixture, name));
}

MPV_EXPORT void mpv_free(void *data)
{
    release_owned_string((char *)data);
}

MPV_EXPORT void mpv_free_node_contents(mpv_node *node)
{
    if (!node || (node->format != MPV_FORMAT_NODE_MAP && node->format != MPV_FORMAT_NODE_ARRAY))
        return;
    mpv_node_list *list = node->u.list;
    release_node_payload(list);
    node->u.list = NULL;
    node->format = MPV_FORMAT_NONE;
}
