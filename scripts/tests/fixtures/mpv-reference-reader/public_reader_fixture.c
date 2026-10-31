/* Recovery v2 fixture proposal / UNCOMPILED / UNRUN. No installed app, account or real service.
 * Reuse the exact controlled loopback/mux implementation without executing its
 * old direct-demux/39-case main. Root pins this required source macro and all
 * its actual includes; no silent fallback to a historical implementation. */
#ifdef NDEBUG
#undef NDEBUG
#endif
int vpr_legacy_direct_fixture_not_run(void);
#define main vpr_legacy_direct_fixture_not_run
#ifndef VPR_GENUINE_RIG_SOURCE
#error "Root must pin the current literal genuine loopback/mux source"
#endif
#include VPR_GENUINE_RIG_SOURCE
#undef main
#include <locale.h>
#include <limits.h>
#include "config.h"
#include "public_fixture.h"
#include "input/cmd.h"
#include "player/command.h"
#include "player/core.h"
#include "player/owned_subtitle.h"
#include "sub/osd_state.h"
#include "mapping_media.inc"

#define VPR_COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))
static uint64_t vpr_identifier = UINT64_C(0x90000000);
static pthread_t vpr_controller;
static atomic_uint vpr_frees[4][3]; // real owned object, decoder, source lease
static atomic_bool vpr_wrong_destructor;

static void vpr_require(bool value, const char *name)
{
    check(value, name);
    fflush(stdout);
    if (!value)
        _Exit(1); // Do not free a still-borrowed object after a failed schedule.
}
static mpv_node vpr_int(int64_t value)
{
    return (mpv_node){.format = MPV_FORMAT_INT64, .u.int64 = value};
}
static mpv_node vpr_string(const char *value)
{
    return (mpv_node){.format = MPV_FORMAT_STRING, .u.string = (char *)value};
}
static bool vpr_map(const mpv_node *n, const char *const *keys,
                    const mpv_format *types, int count, const mpv_node **out)
{
    if (!n || n->format != MPV_FORMAT_NODE_MAP || !n->u.list ||
        n->u.list->num != count || !n->u.list->keys || !n->u.list->values)
        return false;
    for (int i = 0; i < count; i++) out[i] = NULL;
    for (int i = 0; i < count; i++) {
        int k = 0;
        if (!n->u.list->keys[i]) return false;
        while (k < count && strcmp(n->u.list->keys[i], keys[k])) k++;
        if (k == count || out[k] || n->u.list->values[i].format != types[k])
            return false;
        out[k] = &n->u.list->values[i];
    }
    return true;
}
struct vpr_capture {
    int64_t intent, entry, sid, stream;
    int64_t raw_stream, primary_sid;
    bool primary_external, visible;
    double demux_origin;
};
#define VPR_COMMON_KEYS "version", "intent-generation", "entry-id", "reference-sid", \
    "reference-command-index", "reference-stream-index", "demux-origin", \
    "primary-sid", "primary-external", "primary-visible"
#define VPR_COMMON_TYPES MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_INT64, \
    MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_DOUBLE, \
    MPV_FORMAT_INT64, MPV_FORMAT_FLAG, MPV_FORMAT_FLAG
static bool vpr_capture_fields(const mpv_node *const *f, struct vpr_capture *out)
{
    *out = (struct vpr_capture){.intent = f[1]->u.int64, .entry = f[2]->u.int64,
        .sid = f[3]->u.int64, .stream = f[4]->u.int64, .raw_stream = f[5]->u.int64,
        .demux_origin = f[6]->u.double_, .primary_sid = f[7]->u.int64,
        .primary_external = f[8]->u.flag == 1, .visible = f[9]->u.flag == 1};
    return f[0]->u.int64 == 2 && out->intent > 0 && out->entry > 0 &&
        out->sid > 0 && out->sid <= INT_MAX && out->stream >= 0 && out->stream < 128 &&
        out->raw_stream >= 0 && out->raw_stream < 1024 &&
        out->primary_sid >= 0 && out->primary_sid <= INT_MAX &&
        (f[8]->u.flag == 0 || f[8]->u.flag == 1) &&
        (f[9]->u.flag == 0 || f[9]->u.flag == 1) &&
        (out->primary_sid != 0 || !out->primary_external) &&
        isfinite(out->demux_origin) && fabs(out->demux_origin) <= 86400;
}
static bool vpr_capability(mpv_handle *client, struct vpr_capture *out)
{
    static const char *const keys[] = {VPR_COMMON_KEYS};
    static const mpv_format types[] = {VPR_COMMON_TYPES};
    const mpv_node *f[VPR_COUNT(keys)];
    mpv_node n = {0};
    bool ok = mpv_get_property(client, "vortx-subtitle-reference-capability",
        MPV_FORMAT_NODE, &n) >= 0 && vpr_map(&n, keys, types, VPR_COUNT(keys), f);
    if (ok) {
        ok = vpr_capture_fields(f, out);
    }
    mpv_free_node_contents(&n);
    return ok;
}
static bool vpr_same_capture(const struct vpr_capture *a, const struct vpr_capture *b)
{
    return a->intent == b->intent && a->entry == b->entry && a->sid == b->sid &&
        a->stream == b->stream && a->raw_stream == b->raw_stream &&
        a->primary_sid == b->primary_sid && a->primary_external == b->primary_external &&
        a->visible == b->visible && a->demux_origin == b->demux_origin;
}
static const mpv_node *vpr_field(const mpv_node *map, const char *key)
{
    if (!map || map->format != MPV_FORMAT_NODE_MAP || !map->u.list ||
        map->u.list->num < 0 || !map->u.list->keys || !map->u.list->values)
        return NULL;
    const mpv_node *found = NULL;
    for (int i = 0; i < map->u.list->num; i++) {
        if (!map->u.list->keys[i]) return NULL;
        if (!strcmp(map->u.list->keys[i], key)) {
            if (found) return NULL;
            found = &map->u.list->values[i];
        }
    }
    return found;
}
static bool vpr_select_primary(mpv_handle *client)
{
    mpv_node tracks = {0}; int found = 0; int64_t sid = 0;
    bool ok = mpv_get_property(client, "track-list", MPV_FORMAT_NODE, &tracks) >= 0 &&
        tracks.format == MPV_FORMAT_NODE_ARRAY && tracks.u.list &&
        tracks.u.list->num == 2 && tracks.u.list->values;
    for (int i = 0; ok && i < tracks.u.list->num; i++) {
        const mpv_node *row = &tracks.u.list->values[i];
        const mpv_node *type = vpr_field(row, "type"), *id = vpr_field(row, "id");
        if (!type || type->format != MPV_FORMAT_STRING || !type->u.string) { ok = false; break; }
        if (strcmp(type->u.string, "sub")) continue;
        const mpv_node *external = vpr_field(row, "external"), *index = vpr_field(row, "ff-index");
        ok = id && id->format == MPV_FORMAT_INT64 && id->u.int64 > 0 &&
            external && external->format == MPV_FORMAT_FLAG && !external->u.flag &&
            index && index->format == MPV_FORMAT_INT64 && index->u.int64 == 0;
        if (ok) { found++; sid = id->u.int64; }
    }
    mpv_free_node_contents(&tracks);
    return ok && found == 1 && mpv_set_property(client, "sid", MPV_FORMAT_INT64, &sid) >= 0;
}
struct vpr_selection {
    int primary_sid, secondary_sid;
    bool primary_external, secondary_external, visible, secondary_visible;
};
static bool vpr_selection(mpv_handle *client, struct vpr_selection *out)
{
    struct MPContext *core = vpr_real_core(client);
    if (!core) return false;
    mp_core_lock(core);
    struct track *p = core->current_track[0][STREAM_SUB];
    struct track *s = core->current_track[1][STREAM_SUB];
    bool ok = (!p || (p->selected && p->type == STREAM_SUB && p->user_tid > 0)) &&
        (!s || (s->selected && s->type == STREAM_SUB && s->user_tid > 0));
    *out = (struct vpr_selection){.primary_sid = p ? p->user_tid : 0,
        .secondary_sid = s ? s->user_tid : 0, .primary_external = p && p->is_external,
        .secondary_external = s && s->is_external};
    mp_core_unlock(core);
    int visible = -1, secondary = -1;
    ok = ok && mpv_get_property(client, "sub-visibility", MPV_FORMAT_FLAG, &visible) >= 0 &&
        mpv_get_property(client, "secondary-sub-visibility", MPV_FORMAT_FLAG, &secondary) >= 0 &&
        (visible == 0 || visible == 1) && (secondary == 0 || secondary == 1);
    out->visible = visible == 1; out->secondary_visible = secondary == 1;
    return ok;
}
static bool vpr_same_selection(const struct vpr_selection *a, const struct vpr_selection *b)
{
    return a->primary_sid == b->primary_sid && a->secondary_sid == b->secondary_sid &&
        a->primary_external == b->primary_external && a->secondary_external == b->secondary_external &&
        a->visible == b->visible && a->secondary_visible == b->secondary_visible;
}
static void vpr_selection_unchanged(mpv_handle *client, const struct vpr_selection *expected,
                                    const char *name)
{
    struct vpr_selection now;
    vpr_require(vpr_selection(client, &now) && vpr_same_selection(&now, expected), name);
}
static bool vpr_real_reference_mapping(mpv_handle *client, const struct vpr_capture *capture,
                                       bool distinct)
{
    struct MPContext *core = vpr_real_core(client);
    if (!core) return false;
    mp_core_lock(core);
    unsigned matches = 0; bool ok = false;
    for (int n = 0; n < core->num_tracks; n++) {
        struct track *t = core->tracks[n];
        if (t->type != STREAM_SUB || t->user_tid != capture->sid) continue;
        matches++;
        ok = !t->is_external && t->demuxer == core->demuxer && t->stream &&
            t->stream->type == STREAM_SUB && t->ff_index == capture->stream &&
            t->stream->index == capture->raw_stream &&
            (!distinct || t->ff_index != t->stream->index);
    }
    mp_core_unlock(core);
    return ok && matches == 1;
}
static bool vpr_inventory_ready(mpv_handle *client)
{
    struct vpr_capture c; struct vpr_selection visible;
    return vpr_capability(client, &c) && vpr_selection(client, &visible) &&
        visible.primary_sid == 0 && !visible.primary_external &&
        c.primary_sid == 0 && !c.primary_external && vpr_real_reference_mapping(client, &c, false);
}
static void vpr_capture_args(mpv_node *args, const struct vpr_capture *w)
{
    args[0] = vpr_int(w->intent); args[1] = vpr_int(w->entry);
    args[2] = vpr_int(w->sid); args[3] = vpr_int(w->stream);
    args[4] = vpr_int(w->raw_stream); args[5] = vpr_int(w->primary_sid);
    args[6] = vpr_int((w->primary_external ? INT64_C(1) : 0) | (w->visible ? INT64_C(2) : 0));
    args[7] = (mpv_node){.format = MPV_FORMAT_DOUBLE, .u.double_ = w->demux_origin};
}
static uint64_t vpr_submit(mpv_handle *client, const char *name,
                           const mpv_node *args, int count)
{
    vpr_require(count >= 0 && count <= 11 && vpr_identifier < UINT64_MAX, "finite public async command identifier");
    mpv_node values[12] = {vpr_string(name)};
    for (int i = 0; i < count; i++) values[i + 1] = args[i];
    mpv_node_list list = {.num = count + 1, .values = values};
    mpv_node command = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
    uint64_t id = ++vpr_identifier;
    vpr_require(mpv_command_node_async(client, id, &command) >= 0,
                "actual public node async submission accepted");
    return id;
}
static int vpr_reply(mpv_handle *client, uint64_t id,
                      bool (*consume)(const mpv_node *, void *), void *opaque)
{
    int64_t until = mp_time_ns() + CASE_NS;
    while (mp_time_ns() < until) {
        mpv_event *event = mpv_wait_event(client, 0.025);
        if (!event || event->event_id != MPV_EVENT_COMMAND_REPLY || event->reply_userdata != id)
            continue;
        if (event->error < 0)
            return event->error;
        mpv_event_command *reply = event->data;
        vpr_require(reply && consume && consume(&reply->result, opaque),
                    "actual original command reply has its strict expected node shape");
        return 0; // All typed copies precede the next mpv_wait_event call.
    }
    vpr_require(false, "actual command reply completed before finite fixture deadline");
    return MPV_ERROR_GENERIC;
}
static void vpr_reject_old_arity(mpv_handle *client, const char *name,
                                  const mpv_node *args, int count)
{
    vpr_require(count >= 0 && count <= 11 && vpr_identifier < UINT64_MAX,
                "bounded old-arity negative node construction");
    mpv_node values[12] = {vpr_string(name)};
    for (int i = 0; i < count; i++) values[i + 1] = args[i];
    mpv_node_list list = {.num = count + 1, .values = values};
    mpv_node command = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
    vpr_require(mpv_command_node_async(client, ++vpr_identifier, &command) < 0,
                "real public parser rejects old v1 arity before dispatch");
}
static void vpr_wire_negatives(mpv_handle *client)
{
    struct vpr_capture original, after; struct vpr_selection selection;
    vpr_require(mpv_set_property_string(client, "sub-visibility", "no") >= 0 &&
        vpr_capability(client, &after) && after.primary_sid == 0 && !after.visible,
        "actual false global visibility remains a valid hidden-reference capability snapshot");
    vpr_require(mpv_set_property_string(client, "sub-visibility", "yes") >= 0,
                "actual visibility restored before independent read capture");
    vpr_require(vpr_capability(client, &original) && original.primary_sid == 0 &&
        !original.primary_external && vpr_selection(client, &selection),
        "negative wire cases start with genuine hidden reference and primary Off");
    const int64_t bad_masks[] = {-1, 4, 3};
    for (int n = 0; n < VPR_COUNT(bad_masks); n++) {
        mpv_node args[8]; vpr_capture_args(args, &original); args[6] = vpr_int(bad_masks[n]);
        uint64_t id = vpr_submit(client, "vortx-subtitle-reference-read", args, 8);
        vpr_require(vpr_reply(client, id, NULL, NULL) < 0,
                    "real READ rejects reserved mask or external bit while primary Off");
    }
    mpv_node legacy_read[] = {vpr_int(original.intent), vpr_int(original.entry),
        vpr_int(original.sid), vpr_int(original.stream),
        {.format = MPV_FORMAT_DOUBLE, .u.double_ = original.demux_origin}};
    vpr_reject_old_arity(client, "vortx-subtitle-reference-read", legacy_read, 5);
    mpv_node legacy_local[] = {vpr_int(original.intent), vpr_int(original.entry), vpr_int(1),
        vpr_int(original.sid), vpr_int(original.stream),
        {.format = MPV_FORMAT_DOUBLE, .u.double_ = original.demux_origin},
        vpr_string("{\"version\":1,\"language\":\"en\",\"cues\":[{\"startMs\":0,\"endMs\":1000,\"text\":\"fixture\"}]}")};
    vpr_reject_old_arity(client, "vortx-subtitle-owned-prepare", legacy_local, 7);
    mpv_node legacy_local_commit[] = {vpr_int(1), vpr_int(original.intent), vpr_int(original.entry),
        vpr_int(1), vpr_int(original.sid), vpr_int(original.stream),
        {.format = MPV_FORMAT_DOUBLE, .u.double_ = original.demux_origin}};
    vpr_reject_old_arity(client, "vortx-subtitle-owned-commit", legacy_local_commit, 7);
    mpv_node legacy_remote[8] = {vpr_int(1)};
    for (int n = 0; n < 7; n++) legacy_remote[n + 1] = legacy_local[n];
    vpr_reject_old_arity(client, "vortx-subtitle-reference-prepare", legacy_remote, 8);
    mpv_node legacy_commit[] = {vpr_int(1), vpr_int(1), vpr_int(original.intent),
        vpr_int(original.entry), vpr_int(1), vpr_int(original.sid), vpr_int(original.stream),
        {.format = MPV_FORMAT_DOUBLE, .u.double_ = original.demux_origin}};
    vpr_reject_old_arity(client, "vortx-subtitle-reference-commit", legacy_commit, 8);
    vpr_require(vpr_capability(client, &after) && vpr_same_capture(&original, &after),
                "rejected wire commands preserve source and original intent");
    vpr_selection_unchanged(client, &selection,
                            "rejected wire commands preserve primary secondary and both visibility flags");
}
struct vpr_read {
    struct vpr_capture capture;
    int64_t grant, source, response, source_epoch, demux_epoch;
    unsigned count;
};
static bool vpr_consume_read(const mpv_node *n, void *opaque)
{
    static const char *const keys[] = {VPR_COMMON_KEYS, "grant", "source-generation",
        "response-generation", "source-epoch", "demux-epoch", "origin",
        "prefix-start-ms", "prefix-end-ms", "cues"};
    static const mpv_format types[] = {VPR_COMMON_TYPES, MPV_FORMAT_INT64,
        MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_DOUBLE,
        MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_NODE_ARRAY};
    const mpv_node *f[VPR_COUNT(keys)];
    struct vpr_read *r = opaque;
    if (!vpr_map(n, keys, types, VPR_COUNT(keys), f) ||
        f[10]->u.int64 <= 0 || f[11]->u.int64 <= 0 || f[12]->u.int64 <= 0 ||
        f[13]->u.int64 <= 0 || f[14]->u.int64 <= 0 ||
        f[15]->u.double_ != 0 || f[16]->u.int64 != 0 || f[17]->u.int64 != 1080000 ||
        !f[18]->u.list || f[18]->u.list->num != 9 || !f[18]->u.list->values)
        return false;
    struct vpr_capture capture;
    if (!vpr_capture_fields(f, &capture) || !vpr_same_capture(&r->capture, &capture)) return false;
    for (int i = 0; i < 9; i++) {
        const mpv_node *pair = &f[18]->u.list->values[i];
        if (pair->format != MPV_FORMAT_NODE_ARRAY || !pair->u.list ||
            pair->u.list->num != 2 || !pair->u.list->values ||
            pair->u.list->values[0].format != MPV_FORMAT_INT64 ||
            pair->u.list->values[1].format != MPV_FORMAT_INT64 ||
            pair->u.list->values[0].u.int64 != silent_pts[i] ||
            pair->u.list->values[1].u.int64 != silent_pts[i] + silent_duration[i])
            return false;
    }
    r->grant = f[10]->u.int64; r->source = f[11]->u.int64;
    r->response = f[12]->u.int64; r->source_epoch = f[13]->u.int64;
    r->demux_epoch = f[14]->u.int64; r->count = 9;
    return true;
}
struct vpr_ticket {
    int64_t grant, ticket, source;
    struct vpr_capture capture;
    struct vpr_selection selection;
    bool committed;
};
static bool vpr_consume_ticket(const mpv_node *n, void *opaque)
{
    struct vpr_ticket *t = opaque;
    static const char *const keys[] = {"version", "grant", "ticket", "committed"};
    static const mpv_format types[] = {MPV_FORMAT_INT64, MPV_FORMAT_INT64,
        MPV_FORMAT_INT64, MPV_FORMAT_FLAG};
    const mpv_node *f[4];
    if (!vpr_map(n, keys, types, t->committed ? 4 : 3, f) ||
        f[0]->u.int64 != 2 || f[1]->u.int64 != t->grant ||
        f[2]->u.int64 <= 0 || (t->committed &&
        (f[2]->u.int64 != t->ticket || f[3]->u.flag != 1))) return false;
    t->ticket = f[2]->u.int64;
    return true;
}
static bool vpr_consume_revoke(const mpv_node *n, void *opaque)
{
    static const char *const keys[] = {"version", "released"};
    static const mpv_format types[] = {MPV_FORMAT_INT64, MPV_FORMAT_FLAG};
    const mpv_node *f[2];
    if (!vpr_map(n, keys, types, 2, f) || f[0]->u.int64 != 2 ||
        (f[1]->u.flag != 0 && f[1]->u.flag != 1)) return false;
    *(bool *)opaque = f[1]->u.flag;
    return true;
}
static void vpr_original_args(mpv_node *a, const struct vpr_read *r)
{
    a[0] = vpr_int(r->capture.intent); a[1] = vpr_int(r->capture.entry);
    a[2] = vpr_int(r->source); a[3] = vpr_int(r->capture.sid);
    a[4] = vpr_int(r->capture.stream); a[5] = vpr_int(r->capture.raw_stream);
    a[6] = vpr_int(r->capture.primary_sid);
    a[7] = vpr_int((r->capture.primary_external ? INT64_C(1) : 0) |
                  (r->capture.visible ? INT64_C(2) : 0));
    a[8] = (mpv_node){.format = MPV_FORMAT_DOUBLE, .u.double_ = r->capture.demux_origin};
}
static struct vpr_ticket vpr_mount_mode(mpv_handle *client, bool malformed_masks)
{
    struct vpr_read read = {0};
    struct vpr_selection original_selection;
    vpr_require(vpr_selection(client, &original_selection), "actual visible selection snapshot captured before READ");
    vpr_require(vpr_capability(client, &read.capture), "real playing remote primary capability captured");
    vpr_require(read.capture.primary_sid == original_selection.primary_sid &&
        read.capture.primary_external == original_selection.primary_external &&
        read.capture.visible == original_selection.visible &&
        vpr_real_reference_mapping(client, &read.capture, false),
        "v2 reference IDs match real inventory independently of actual visible primary");
    mpv_node args[11]; vpr_capture_args(args, &read.capture);
    uint64_t id = vpr_submit(client, "vortx-subtitle-reference-read", args, 8);
    vpr_require(vpr_reply(client, id, vpr_consume_read, &read) == 0,
                "real public READ returned all nine exact original timing pairs");
    vpr_selection_unchanged(client, &original_selection,
                            "READ preserves actual primary secondary and both visibility flags");
    args[0] = vpr_int(read.grant); vpr_original_args(&args[1], &read);
    args[10] = vpr_string("{\"version\":1,\"language\":\"en\",\"cues\":["
        "{\"startMs\":0,\"endMs\":200000,\"text\":\"genuine remote owned subtitle pixels\"}]}");
    struct vpr_ticket ticket = {.grant = read.grant, .source = read.source,
        .capture = read.capture, .selection = original_selection};
    if (malformed_masks) {
        mpv_node bad[11]; memcpy(bad, args, sizeof(bad)); bad[8] = vpr_int(4);
        id = vpr_submit(client, "vortx-subtitle-reference-prepare", bad, 11);
        vpr_require(vpr_reply(client, id, NULL, NULL) < 0,
                    "actual PREPARE rejects reserved flag bits on a real retained grant");
    }
    id = vpr_submit(client, "vortx-subtitle-reference-prepare", args, 11);
    vpr_require(vpr_reply(client, id, vpr_consume_ticket, &ticket) == 0,
                "real public PREPARE returned complete native decoder ticket");
    vpr_selection_unchanged(client, &original_selection,
                            "PREPARE preserves actual primary secondary and both visibility flags");
    args[0] = vpr_int(ticket.ticket); args[1] = vpr_int(read.grant);
    vpr_original_args(&args[2], &read); ticket.committed = true;
    if (malformed_masks) {
        mpv_node bad[11]; memcpy(bad, args, sizeof(bad)); bad[9] = vpr_int(4);
        id = vpr_submit(client, "vortx-subtitle-reference-commit", bad, 11);
        vpr_require(vpr_reply(client, id, NULL, NULL) < 0,
                    "actual COMMIT rejects reserved flag bits on a real prepared ticket");
    }
    id = vpr_submit(client, "vortx-subtitle-reference-commit", args, 11);
    vpr_require(vpr_reply(client, id, vpr_consume_ticket, &ticket) == 0,
                "real public COMMIT admitted exact grant and original scalar witness");
    vpr_selection_unchanged(client, &original_selection,
                            "COMMIT preserves actual primary secondary and both visibility flags");
    return ticket;
}
static struct vpr_ticket vpr_mount(mpv_handle *client)
{
    return vpr_mount_mode(client, false);
}
static bool vpr_active(mpv_handle *client, const struct vpr_ticket *ticket)
{
    static const char *const keys[] = {VPR_COMMON_KEYS, "grant", "ticket", "source-generation"};
    static const mpv_format types[] = {VPR_COMMON_TYPES, MPV_FORMAT_INT64, MPV_FORMAT_INT64, MPV_FORMAT_INT64};
    const mpv_node *f[13]; mpv_node n = {0}; struct vpr_capture capture;
    bool ok = mpv_get_property(client, "vortx-subtitle-reference-active", MPV_FORMAT_NODE, &n) >= 0 &&
        vpr_map(&n, keys, types, 13, f) && vpr_capture_fields(f, &capture) &&
        vpr_same_capture(&capture, &ticket->capture) &&
        f[10]->u.int64 == ticket->grant && f[11]->u.int64 == ticket->ticket &&
        f[12]->u.int64 == ticket->source;
    mpv_free_node_contents(&n); return ok;
}
struct vpr_marker { unsigned id, kind; };
static void vpr_destroyed(void *p)
{
    struct vpr_marker *m = p;
    if (pthread_equal(pthread_self(), vpr_controller))
        atomic_store(&vpr_wrong_destructor, true);
    atomic_fetch_add_explicit(&vpr_frees[m->id][m->kind], 1, memory_order_release);
}
static void vpr_mark(void *parent, unsigned id, unsigned kind)
{
    struct vpr_marker *m = talloc_zero(parent, struct vpr_marker);
    *m = (struct vpr_marker){id, kind}; talloc_set_destructor(m, vpr_destroyed);
}
static void vpr_observe(struct MPContext *core, const struct vpr_ticket *ticket, unsigned id)
{
    struct vortx_owned_text *o = osd_vortx_owned_text_current(core->osd);
    vpr_require(o && o->ticket == ticket->ticket && o->decoder && o->source_lease &&
        o->source_current && o->source_release && o->source_current(o->source_lease),
        "genuine current OSD object retains its valid owned remote source lease");
    vpr_mark(o, id, 0); vpr_mark(o->source_lease, id, 2);
    vpr_decoder_lock(o->decoder); vpr_mark(o->decoder, id, 1); vpr_decoder_unlock(o->decoder);
}
static bool vpr_destroyed_once(unsigned id)
{
    for (unsigned kind = 0; kind < 3; kind++)
        if (atomic_load_explicit(&vpr_frees[id][kind], memory_order_acquire) != 1)
            return false;
    return !atomic_load(&vpr_wrong_destructor);
}
static bool vpr_not_destroyed(unsigned id)
{
    for (unsigned kind = 0; kind < 3; kind++)
        if (atomic_load_explicit(&vpr_frees[id][kind], memory_order_acquire)) return false;
    return true;
}
static void vpr_wait_drained(struct MPContext *core, unsigned id)
{
    int64_t until = mp_time_ns() + CASE_NS; bool done = false;
    while (!done && mp_time_ns() < until) {
        mp_core_lock(core);
        done = core->outstanding_async == 0 && !osd_vortx_owned_text_current(core->osd);
        mp_core_unlock(core);
        done = done && vpr_destroyed_once(id);
        if (!done) pause_ms(1);
    }
    vpr_require(done, "real reaper drained exact owner decoder and source lease once off controller");
}
static uint64_t vpr_bitmap_hash(struct sub_bitmap_list *list)
{
    vpr_require(list && list->num_items == 1, "one genuine rendered primary bitmap item");
    struct sub_bitmaps *images = list->items[0];
    vpr_require(images && images->render_index == OSDTYPE_SUB && images->packed &&
        images->num_parts > 0 && images->num_parts <= 1024 &&
        (images->format == SUBBITMAP_LIBASS || images->format == SUBBITMAP_BGRA),
        "actual libass or BGRA packed subtitle bitmap present");
    uint64_t hash = UINT64_C(1469598103934665603); bool nonzero = false; size_t total = 0;
    for (int n = 0; n < images->num_parts; n++) {
        struct sub_bitmap *p = &images->parts[n];
        int bytes = images->format == SUBBITMAP_BGRA ? 4 : 1;
        vpr_require(p->bitmap && p->w > 0 && p->w <= 4096 && p->h > 0 && p->h <= 4096 &&
            p->stride >= p->w * bytes, "bounded genuine bitmap row layout");
        total += (size_t)p->w * p->h * bytes;
        vpr_require(total <= 64u * 1024u * 1024u, "bounded genuine pixel byte scan");
        for (int y = 0; y < p->h; y++) {
            const unsigned char *row = (const unsigned char *)p->bitmap + (size_t)y * p->stride;
            for (int x = 0; x < p->w * bytes; x++) {
                nonzero |= row[x] != 0; hash = (hash ^ row[x]) * UINT64_C(1099511628211);
            }
        }
    }
    vpr_require(nonzero, "real native owned ASS renderer produced nonzero pixels");
    return hash;
}
struct vpr_render_job { struct osd_state *osd; double pts; struct sub_bitmap_list *result; };
static void *vpr_render_thread(void *p)
{
    struct vpr_render_job *job = p; job->result = vpr_render(job->osd, job->pts); return NULL;
}
struct vpr_completion { unsigned count; bool released; };
static void vpr_completed(struct mp_cmd_ctx *cmd)
{
    struct vpr_completion *done = cmd->on_completion_priv; done->count++;
    bool released = false;
    done->released = cmd->success && vpr_consume_revoke(&cmd->result, &released) && released;
}
static void vpr_held_revoke(mpv_handle *client, const struct vpr_ticket *ticket)
{
    struct MPContext *core = vpr_real_core(client);
    mp_core_lock(core); // Do not acquire core after starting the held reader.
    struct osd_state *osd = core->osd;
    struct vortx_owned_text *old = osd_vortx_owned_text_current(osd);
    vpr_require(old && old->ticket == ticket->ticket && core->outstanding_async == 0 &&
        atomic_load(&osd->vortx_owned_text.readers) == 0, "real held-reader schedule starts quiescent");
    double forced = osd_get_force_video_pts(osd);
    double pts = forced == MP_NOPTS_VALUE ? 1.5 : forced;
    vpr_require(isfinite(pts) && pts >= 0 && pts < 200, "real renderer time falls inside fixture cue");
    struct sub_bitmap_list *saved = vpr_render(osd, pts);
    uint64_t before = vpr_bitmap_hash(saved);
    vpr_arm_reader(old->decoder);
    struct vpr_render_job job = {.osd = osd, .pts = pts}; pthread_t render;
    vpr_require(pthread_create(&render, NULL, vpr_render_thread, &job) == 0, "real OSD render thread started");
    int64_t until = mp_time_ns() + CASE_NS;
    while ((!vpr_reader_selected() || atomic_load(&osd->vortx_owned_text.readers) != 1) && mp_time_ns() < until)
        pause_ms(1);
    vpr_require(vpr_reader_selected() && atomic_load(&osd->vortx_owned_text.readers) == 1,
                "actual OSD reader retained exact object and reached genuine decoder lock");
    // A synchronous public command while holding decoder/core would deadlock.
    // Parse and execute the exact real synchronous REVOKE definition on the
    // already-held genuine core, as in the accepted manager-reader fixture.
    mpv_node values[] = {vpr_string("vortx-subtitle-reference-revoke"), vpr_int(ticket->grant)};
    mpv_node_list list = {.num = 2, .values = values};
    mpv_node node = {.format = MPV_FORMAT_NODE_ARRAY, .u.list = &list};
    struct mp_cmd *cmd = mp_input_parse_cmd_node(core->log, &node);
    vpr_require(cmd && cmd->def && cmd->def->handler == cmd_vortx_subtitle_reference_revoke &&
        !cmd->def->spawn_thread && !cmd->def->exec_async && !cmd->def->can_abort,
        "actual command table parsed exact synchronous grant revoke handler");
    struct vpr_completion complete = {0}; run_command(core, cmd, NULL, vpr_completed, &complete);
    vpr_require(complete.count == 1 && complete.released && !osd_vortx_owned_text_current(osd),
                "real command retired exact grant before borrowed object could be destroyed");
    while (!atomic_load(&osd->vortx_owned_text.waiting) && mp_time_ns() < until) pause_ms(1);
    vpr_require(atomic_load(&osd->vortx_owned_text.waiting) && core->outstanding_async > 0 &&
        vpr_not_destroyed(0), "real reaper waits for held OSD reader before decoder and source release");
    struct dec_sub *decoder = old->decoder;
    vpr_release_reader(decoder); // No use of old/decoder after this unlock.
    vpr_require(pthread_join(render, NULL) == 0, "real held renderer joined");
    vpr_require(!job.result || job.result->num_items == 0,
                "post-bitmap source and slot checks suppress revoked subtitle output");
    talloc_free(job.result); mp_core_unlock(core);
    vpr_wait_drained(core, 0);
    vpr_require(vpr_bitmap_hash(saved) == before,
                "previously copied genuine pixels remain valid after decoder source and owner destruction");
    talloc_free(saved);
}
static mpv_handle *vpr_load_mode(struct server *server, const char *config_dir, bool select_primary)
{
    mpv_handle *client = mpv_create(); vpr_require(client != NULL, "real isolated libmpv client created");
    static const char *const options[][2] = {
        {"config", "no"}, {"load-scripts", "no"}, {"terminal", "no"},
        {"input-terminal", "no"}, {"input-default-bindings", "no"}, {"input-vo-keyboard", "no"},
        {"vo", "null"}, {"ao", "null"}, {"pause", "yes"}, {"idle", "yes"}, {"keep-open", "yes"},
        {"demuxer", "lavf"}, {"sub-auto", "no"}, {"sid", "no"}, {"rebase-start-time", "yes"},
        {"sub-delay", "0"}, {"sub-speed", "1"}, {"sub-fps", "0"}, {"sub-visibility", "yes"},
        {"secondary-sid", "no"}, {"secondary-sub-visibility", "no"}, {"tls-verify", "yes"},
    };
    for (int i = 0; i < VPR_COUNT(options); i++)
        vpr_require(mpv_set_option_string(client, options[i][0], options[i][1]) >= 0,
                    "genuine isolated player option accepted");
#if HAVE_LUA
    vpr_require(mpv_set_option_string(client, "osc", "no") >= 0, "compiled Lua OSC disabled");
#endif
    vpr_require(stream_options(client) && mpv_set_option_string(client, "config-dir", config_dir) >= 0 &&
        mpv_initialize(client) >= 0, "real client initialized with explicit direct fixture transport");
    const char *load[] = {"loadfile", server->url, "replace", NULL};
    vpr_require(mpv_command(client, load) >= 0, "controlled loopback media entered ordinary public loadfile path");
    struct vpr_capture capture; int64_t until = mp_time_ns() + CASE_NS; bool selected = false;
    while (mp_time_ns() < until) {
        if (!selected) selected = select_primary ? vpr_select_primary(client) : vpr_inventory_ready(client);
        if (selected && vpr_capability(client, &capture)) break;
        mpv_wait_event(client, 0.025);
    }
    vpr_require(selected && vpr_capability(client, &capture), select_primary ?
        "real loaded core selected its actual embedded primary" :
        "real loaded core kept primary Off and acquired a hidden embedded reference");
    vpr_require(vpr_real_core(client) && vpr_real_core(client)->osd, "typed whole-client getter exposes genuine OSD");
    return client;
}
static mpv_handle *vpr_load(struct server *server, const char *config_dir)
{
    return vpr_load_mode(server, config_dir, true);
}
static void vpr_write_external(const char *config_dir, const char *name, char *out, size_t size)
{
    int length = snprintf(out, size, "%s/%s", config_dir, name);
    vpr_require(length > 0 && (size_t)length < size, "disposable subtitle path stays inside fresh config directory");
    int fd = open(out, O_WRONLY | O_CREAT | O_EXCL, 0600);
    vpr_require(fd >= 0, "disposable external subtitle created exclusively");
    const char text[] = "1\n00:01:30,000 --> 00:01:31,000\nordinary external fixture\n";
    size_t offset = 0;
    while (offset < sizeof(text) - 1) {
        ssize_t written = write(fd, text + offset, sizeof(text) - 1 - offset);
        if (written < 0 && errno == EINTR) continue;
        vpr_require(written > 0, "disposable external subtitle write completed");
        offset += (size_t)written;
    }
    vpr_require(close(fd) == 0, "disposable external subtitle closed");
}
static int vpr_external_receipt(mpv_handle *client, const char *path, bool selected)
{
    struct MPContext *core = vpr_real_core(client);
    mp_core_lock(core); unsigned found = 0; int sid = 0;
    for (int n = 0; n < core->num_tracks; n++) {
        struct track *t = core->tracks[n];
        if (t->type == STREAM_SUB && t->is_external && t->external_filename &&
            !strcmp(t->external_filename, path)) {
            found++; sid = t->user_tid;
            if (sid <= 0 || t->selected != selected ||
                (selected && core->current_track[0][STREAM_SUB] != t)) sid = 0;
        }
    }
    mp_core_unlock(core);
    vpr_require(found == 1 && sid > 0, "exact ordinary sub-add receipt names the real external track and selection");
    return sid;
}
static void vpr_positive_cases(const char *config_dir)
{
    struct memory_file media = {0};
    vpr_require(make_media(&media, false, false, true) == 0, "real bounded mux/demux verifies PCM zero and nine SubRip cues");
    struct server server = {.listener = -1, .active = -1, .wire_ok = true, .media = &media};
    atomic_init(&server.stop, false); vpr_require(pthread_mutex_init(&server.lock, NULL) == 0, "real fixture server mutex initialized");
    vpr_require(server_start(&server) == 0, "literal existing controlled loopback listener started");
    mpv_handle *client = vpr_load_mode(&server, config_dir, false);
    vpr_wire_negatives(client);
    struct vpr_ticket ticket = vpr_mount_mode(client, true);
    vpr_require(ticket.capture.primary_sid == 0 && !ticket.capture.primary_external,
                "Off to READ PREPARE COMMIT used hidden reference without selecting it");
    vpr_require(vpr_active(client, &ticket), "strict active lookup binds actual remote OSD grant and ticket");
    struct MPContext *core = vpr_real_core(client);
    mp_core_lock(core); vpr_observe(core, &ticket, 0); mp_core_unlock(core);
    vpr_held_revoke(client, &ticket);
    vpr_selection_unchanged(client, &ticket.selection, "held-reader retirement preserves original Off and visibility state");

    char primary_file[4096], secondary_file[4096];
    vpr_write_external(config_dir, "v2-secondary.srt", secondary_file, sizeof(secondary_file));
    const char *cache[] = {"sub-add", secondary_file, "auto", NULL};
    vpr_require(mpv_command(client, cache) >= 0, "real ordinary unselected external subtitle added before primary mount");
    int64_t secondary = vpr_external_receipt(client, secondary_file, false);
    vpr_require(mpv_set_property(client, "secondary-sid", MPV_FORMAT_INT64, &secondary) >= 0 &&
        mpv_set_property_string(client, "secondary-sub-visibility", "yes") >= 0,
        "real secondary external subtitle and visibility established before primary mount");
    vpr_write_external(config_dir, "v2-primary.srt", primary_file, sizeof(primary_file));
    const char *mount[] = {"sub-add", primary_file, "select", NULL};
    vpr_require(mpv_command(client, mount) >= 0, "real ordinary primary external sub-add completed before hidden READ");
    int primary = vpr_external_receipt(client, primary_file, true);

    ticket = vpr_mount(client);
    vpr_require(ticket.selection.primary_sid == primary && ticket.selection.primary_external &&
        ticket.selection.secondary_sid == secondary && ticket.selection.secondary_external &&
        ticket.selection.secondary_visible && ticket.capture.sid != primary,
        "ordinary external mount receipt precedes hidden embedded reference READ");
    mp_core_lock(core); vpr_observe(core, &ticket, 1); mp_core_unlock(core);
    double delay = 0.125;
    vpr_require(mpv_set_property(client, "sub-delay", MPV_FORMAT_DOUBLE, &delay) >= 0,
                "actual public manual subtitle delay retires remote alignment");
    vpr_wait_drained(core, 1);
    vpr_selection_unchanged(client, &ticket.selection, "manual timing retirement preserves primary secondary and visibility state");
    delay = 0;
    vpr_require(mpv_set_property(client, "sub-delay", MPV_FORMAT_DOUBLE, &delay) >= 0,
                "actual manual option restored without reviving old grant");

    ticket = vpr_mount(client);
    mp_core_lock(core); vpr_observe(core, &ticket, 2); mp_core_unlock(core);
    mpv_node revoke[] = {vpr_int(ticket.grant)}; bool released = false;
    uint64_t id = vpr_submit(client, "vortx-subtitle-reference-revoke", revoke, 1);
    vpr_require(vpr_reply(client, id, vpr_consume_revoke, &released) == 0 && released,
                "actual public async REVOKE removes its original active grant");
    vpr_wait_drained(core, 2);
    vpr_selection_unchanged(client, &ticket.selection, "exact public revoke preserves primary secondary and visibility state");
    released = true; id = vpr_submit(client, "vortx-subtitle-reference-revoke", revoke, 1);
    vpr_require(vpr_reply(client, id, vpr_consume_revoke, &released) == 0 && !released,
                "repeat exact public revoke certifies absence without reviving source");

    ticket = vpr_mount(client);
    mp_core_lock(core); vpr_observe(core, &ticket, 3); mp_core_unlock(core);
    vpr_require(vpr_active(client, &ticket) && vpr_not_destroyed(3), "real remote grant active immediately before natural termination");
    mpv_terminate_destroy(client); client = NULL; core = NULL;
    vpr_require(vpr_destroyed_once(3), "natural last-client API returned after remote owner decoder and source cleanup");
    vpr_require(server_finish(&server) == 0 && server.duplicate_requests == 4,
                "exact four public reader requests used controlled original request framing");
    pthread_mutex_destroy(&server.lock); av_free(media.bytes);
    vpr_require(unlink(primary_file) == 0 && unlink(secondary_file) == 0,
                "only the two exclusively created disposable subtitle files were removed");
}
static void vpr_distinct_mapping_case(const char *config_dir)
{
    struct memory_file media = {0};
    vpr_require(v2_make_mapping_media(&media) == 0,
                "genuine MOV mux and demux preserve DATA PCM and nine MOV_TEXT timings");
    struct server server = {.listener = -1, .active = -1, .wire_ok = true, .media = &media};
    atomic_init(&server.stop, false);
    vpr_require(pthread_mutex_init(&server.lock, NULL) == 0 && server_start(&server) == 0,
                "distinct mapping uses the same real controlled loopback server");
    mpv_handle *client = vpr_load_mode(&server, config_dir, false);
    struct vpr_capture capture;
    vpr_require(vpr_capability(client, &capture) && capture.stream == 2 && capture.raw_stream == 1 &&
        vpr_real_reference_mapping(client, &capture, true),
        "actual FF command index2 differs from actual MPV raw reference index1");
    struct vpr_ticket ticket = vpr_mount(client);
    vpr_require(vpr_active(client, &ticket), "distinct actual reference mapping survives READ PREPARE COMMIT");
    bool released = false; mpv_node args[] = {vpr_int(ticket.grant)};
    uint64_t id = vpr_submit(client, "vortx-subtitle-reference-revoke", args, 1);
    vpr_require(vpr_reply(client, id, vpr_consume_revoke, &released) == 0 && released,
                "distinct mapping grant revoked through real public command");
    vpr_selection_unchanged(client, &ticket.selection,
                            "distinct mapping retirement preserves actual Off and both visibility states");
    mpv_terminate_destroy(client);
    vpr_require(server_finish(&server) == 0 && server.duplicate_requests == 1,
                "distinct mapping used exactly one finite genuine duplicate request");
    pthread_mutex_destroy(&server.lock); av_free(media.bytes);
}
static void vpr_abort_case(const char *config_dir)
{
    struct memory_file media = {0};
    vpr_require(make_media(&media, false, false, true) == 0, "real abort media mux/demux prerequisite");
    struct server server = {.listener = -1, .active = -1, .wire_ok = true,
        .media = &media, .mode = RESPONSE_STALL};
    atomic_init(&server.stop, false); vpr_require(pthread_mutex_init(&server.lock, NULL) == 0, "real abort server mutex initialized");
    vpr_require(server_start(&server) == 0, "real abort loopback listener started");
    mpv_handle *client = vpr_load(&server, config_dir);
    struct vpr_capture original, after; vpr_require(vpr_capability(client, &original), "original abort source capability captured");
    unsigned before = atomic_load_explicit(&body_waits, memory_order_acquire);
    mpv_node args[8]; vpr_capture_args(args, &original);
    uint64_t id = vpr_submit(client, "vortx-subtitle-reference-read", args, 8);
    int64_t until = mp_time_ns() + CASE_NS; bool blocked = false;
    while (!blocked && mp_time_ns() < until) {
        pthread_mutex_lock(&server.lock); blocked = server.duplicate_headers_sent; pthread_mutex_unlock(&server.lock);
        blocked = blocked && atomic_load_explicit(&body_waits, memory_order_acquire) > before;
        if (!blocked) pause_ms(1);
    }
    vpr_require(blocked && !atomic_load(&server.stop), "actual command worker blocked inside genuine HTTP body read");
    mpv_abort_async_command(client, id);
    vpr_require(vpr_reply(client, id, NULL, NULL) < 0, "public async abort returned negative read result without a grant");
    bool closed = false;
    while (!closed && mp_time_ns() < until) {
        pthread_mutex_lock(&server.lock); closed = server.duplicate_peer_closed; pthread_mutex_unlock(&server.lock);
        if (!closed) pause_ms(1);
    }
    vpr_require(closed && mp_time_ns() < until && !atomic_load(&server.stop),
                "native abort closed real duplicate socket before deadline or server release");
    vpr_require(vpr_capability(client, &after) && vpr_same_capture(&original, &after),
                "read-only request abort preserves original playback source and manual intent");
    mpv_terminate_destroy(client);
    vpr_require(server_finish(&server) == 0 && server.duplicate_requests == 1,
                "one actual blocked duplicate request ended with genuine client shutdown");
    pthread_mutex_destroy(&server.lock); av_free(media.bytes);
}
#ifndef VPR_FIXTURE_ENTRY
#define VPR_FIXTURE_ENTRY main
#endif
int VPR_FIXTURE_ENTRY(int argc, char **argv)
{
    if (argc != 2 || argv[1][0] != '/') return 2;
    setlocale(LC_NUMERIC, "C"); mp_time_init(); vpr_controller = pthread_self();
    vpr_positive_cases(argv[1]); vpr_abort_case(argv[1]); vpr_distinct_mapping_case(argv[1]);
    printf("RESULT checks=%u failures=%u real_public_async=true real_playing_core=true "
        "real_osd_pixels=true held_reader=true remote_source_release=true real_loopback=true "
        "old_direct_cases_run=false pending_expiry_schedule=false natural_held_reader=false "
        "hidden_reference_off=true hidden_reference_external=true distinct_real_mapping=true "
        "malformed_v2_mask=true old_v1_arity_rejected=true "
        "native_mkv_reference=false local_state_v2=false external_network=false "
        "swift_owner=false full_alignment=false\n", checks, failures);
    return failures ? 1 : 0;
}
