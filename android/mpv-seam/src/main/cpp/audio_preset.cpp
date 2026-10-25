// VortX session-only audio preset transaction. No arbitrary filter text crosses JNI.
// Caller holds MpvSeam.audioFilterLock and one live handleGate lease for this whole call.
#include <jni.h>
#include <mpv/client.h>

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>

#include "globals.h"
#include "jni_utils.h"

extern "C" {
    jni_func(jintArray, nativeSetSessionAudioPreset,
             jlong instance, jint preset, jlong expectedEntryID);
}

namespace {

enum Preset : int { NORMAL = 0, DIALOGUE = 1, NIGHT = 2 };
enum Status : jint {
    APPLIED = 0,
    UNCHANGED = 1,
    REJECTED_RESTORED = 2,
    ROLLBACK_FAILED = 3,
    UNAVAILABLE = 4,
};
constexpr jint UNKNOWN = -1;
constexpr int MAX_FILTERS = 256;
constexpr int MAX_PARAMS = 256;
constexpr int MAX_PLAYLIST_ENTRIES = 4096;
constexpr char LABEL[] = "vortx-session-audio-preset";
constexpr char COMMAND_LABEL[] = "@vortx-session-audio-preset";
constexpr char DIALOGUE_GRAPH[] =
    "equalizer=f=1800:t=q:w=1:g=3,alimiter=limit=0.95:level=0";
constexpr char NIGHT_GRAPH[] =
    "acompressor=threshold=0.125:ratio=4:attack=20:release=250:makeup=1";
constexpr char DIALOGUE_FILTER[] =
    "@vortx-session-audio-preset:lavfi=[equalizer=f=1800:t=q:w=1:g=3,"
    "alimiter=limit=0.95:level=0]";
constexpr char NIGHT_FILTER[] =
    "@vortx-session-audio-preset:lavfi=[acompressor=threshold=0.125:ratio=4:"
    "attack=20:release=250:makeup=1]";

struct Receipt { jint status; jint observed; };

// mpv owns these immutable contents; retain the complete typed tree until rollback is finished.
class NodeSnapshot final {
public:
    NodeSnapshot() = default;
    ~NodeSnapshot() { mpv_free_node_contents(&node_); }
    NodeSnapshot(const NodeSnapshot &) = delete;
    NodeSnapshot &operator=(const NodeSnapshot &) = delete;

    bool read(mpv_handle *handle, const char *property) {
        return mpv_get_property(handle, property, MPV_FORMAT_NODE, &node_) >= 0;
    }
    const mpv_node &get() const { return node_; }
    mpv_node *data() { return &node_; }

private:
    mpv_node node_{};
};

bool isString(const mpv_node &node) {
    return node.format == MPV_FORMAT_STRING && node.u.string;
}

bool isList(const mpv_node &node, mpv_format format, int maximum) {
    if (node.format != format || !node.u.list || node.u.list->num < 0 ||
        node.u.list->num > maximum)
        return false;
    const auto &list = *node.u.list;
    if (list.num > 0 && (!list.values || (format == MPV_FORMAT_NODE_MAP && !list.keys)))
        return false;
    if (format != MPV_FORMAT_NODE_MAP)
        return true; // Never inspect an ARRAY's unused keys member.
    for (int i = 0; i < list.num; ++i) {
        if (!list.keys[i])
            return false;
        for (int j = 0; j < i; ++j) {
            if (std::strcmp(list.keys[i], list.keys[j]) == 0)
                return false;
        }
    }
    return true;
}

// Only called for a map already accepted by isList(). Map key order is unspecified by client.h.
const mpv_node *member(const mpv_node &map, const char *key) {
    for (int i = 0; i < map.u.list->num; ++i) {
        if (std::strcmp(map.u.list->keys[i], key) == 0)
            return &map.u.list->values[i];
    }
    return nullptr;
}

bool validParams(const mpv_node &params) {
    if (!isList(params, MPV_FORMAT_NODE_MAP, MAX_PARAMS))
        return false;
    for (int i = 0; i < params.u.list->num; ++i) {
        if (!isString(params.u.list->values[i]))
            return false;
    }
    return true;
}

bool validFilter(const mpv_node &filter) {
    if (!isList(filter, MPV_FORMAT_NODE_MAP, 4))
        return false;
    const mpv_node *name = member(filter, "name");
    if (!name || !isString(*name) || !name->u.string[0])
        return false;
    for (int i = 0; i < filter.u.list->num; ++i) {
        const char *key = filter.u.list->keys[i];
        const mpv_node &value = filter.u.list->values[i];
        if (std::strcmp(key, "name") == 0 || std::strcmp(key, "label") == 0) {
            if (!isString(value))
                return false;
        } else if (std::strcmp(key, "enabled") == 0) {
            if (value.format != MPV_FORMAT_FLAG || (value.u.flag != 0 && value.u.flag != 1))
                return false;
        } else if (std::strcmp(key, "params") == 0) {
            if (!validParams(value))
                return false;
        } else {
            return false; // The AF setter ignores unknown fields: not a lossless rollback shape.
        }
    }
    return true;
}

bool validAF(const mpv_node &af) {
    if (!isList(af, MPV_FORMAT_NODE_ARRAY, MAX_FILTERS))
        return false;
    for (int i = 0; i < af.u.list->num; ++i) {
        if (!validFilter(af.u.list->values[i]))
            return false;
    }
    return true;
}

// Inputs have the bounded AF schema above; recursion has at most ARRAY -> MAP -> MAP -> STRING.
bool equalNodes(const mpv_node &a, const mpv_node &b) {
    if (a.format != b.format)
        return false;
    if (a.format == MPV_FORMAT_STRING)
        return std::strcmp(a.u.string, b.u.string) == 0;
    if (a.format == MPV_FORMAT_FLAG)
        return a.u.flag == b.u.flag;
    if (a.format != MPV_FORMAT_NODE_ARRAY && a.format != MPV_FORMAT_NODE_MAP)
        return false;
    if (a.u.list->num != b.u.list->num)
        return false;
    for (int i = 0; i < a.u.list->num; ++i) {
        const mpv_node *other = a.format == MPV_FORMAT_NODE_ARRAY
            ? &b.u.list->values[i] : member(b, a.u.list->keys[i]);
        if (!other || !equalNodes(a.u.list->values[i], *other))
            return false;
    }
    return true;
}

int ownedIndex(const mpv_node &af) {
    int index = -1;
    for (int i = 0; i < af.u.list->num; ++i) {
        const mpv_node *label = member(af.u.list->values[i], "label");
        if (label && std::strcmp(label->u.string, LABEL) == 0) {
            if (index != -1)
                return -2;
            index = i;
        }
    }
    return index;
}

bool matchesRecipe(const mpv_node &filter, int preset) {
    if (preset != DIALOGUE && preset != NIGHT)
        return false;
    const mpv_node *name = member(filter, "name");
    const mpv_node *label = member(filter, "label");
    const mpv_node *enabled = member(filter, "enabled");
    const mpv_node *params = member(filter, "params");
    if (!name || !label || !params || std::strcmp(name->u.string, "lavfi") != 0 ||
        std::strcmp(label->u.string, LABEL) != 0 || (enabled && enabled->u.flag != 1) ||
        params->u.list->num != 1)
        return false;
    const mpv_node *graph = member(*params, "graph");
    return graph && std::strcmp(graph->u.string,
                               preset == DIALOGUE ? DIALOGUE_GRAPH : NIGHT_GRAPH) == 0;
}

jint observeOriginal(MPVInstance *instance, const mpv_node &af, int index) {
    if (index == -1) {
        instance->session_audio_preset_owned = NORMAL;
        return NORMAL;
    }
    const int witness = instance->session_audio_preset_owned;
    if (index < 0 || !matchesRecipe(af.u.list->values[index], witness)) {
        instance->session_audio_preset_owned = NORMAL;
        return UNKNOWN; // A matching label alone is not proof of ownership.
    }
    return witness;
}

bool readInt64(mpv_handle *handle, const char *property, int64_t &result) {
    NodeSnapshot node;
    if (!node.read(handle, property) || node.get().format != MPV_FORMAT_INT64)
        return false;
    result = node.get().u.int64;
    return true;
}

bool matchesEntry(mpv_handle *handle, int64_t expected) {
    int64_t position = -1;
    int64_t id = -1;
    if (!readInt64(handle, "playlist-playing-pos", position) || position < 0)
        return false;
    char property[80];
    const int length = std::snprintf(property, sizeof(property), "playlist/%" PRId64 "/id", position);
    if (length < 0 || static_cast<size_t>(length) >= sizeof(property))
        return false;
    if (!readInt64(handle, property, id) || id != expected)
        return false;
    // One NODE gives a coherent playing/id pair; independent index reads alone can be torn.
    NodeSnapshot playlist;
    if (!playlist.read(handle, "playlist") ||
        !isList(playlist.get(), MPV_FORMAT_NODE_ARRAY, MAX_PLAYLIST_ENTRIES))
        return false;
    int playingIndex = -1;
    const auto &entries = *playlist.get().u.list;
    for (int i = 0; i < entries.num; ++i) {
        const mpv_node &entry = entries.values[i];
        if (!isList(entry, MPV_FORMAT_NODE_MAP, 64))
            return false;
        const mpv_node *playing = member(entry, "playing");
        if (!playing)
            continue;
        if (playing->format != MPV_FORMAT_FLAG || playing->u.flag != 1 || playingIndex >= 0)
            return false;
        const mpv_node *entryID = member(entry, "id");
        if (!entryID || entryID->format != MPV_FORMAT_INT64 || entryID->u.int64 != expected)
            return false;
        playingIndex = i;
    }
    return playingIndex >= 0 && static_cast<int64_t>(playingIndex) == position;
}

bool decodedPCMIntent(mpv_handle *handle) {
    // audio-spdif's native NODE format is a codec list; its raw STRING is empty for no codecs.
    // This scalar availability read is not an AF snapshot or rollback serialization.
    char *value = nullptr;
    const int status = mpv_get_property(handle, "audio-spdif", MPV_FORMAT_STRING, &value);
    const std::unique_ptr<char, decltype(&mpv_free)> spdif(value, &mpv_free);
    return status >= 0 && spdif && !spdif.get()[0];
}

bool customFiltersEqual(const mpv_node &before, int oldIndex,
                        const mpv_node &after, int newIndex) {
    const int beforeCount = before.u.list->num - (oldIndex >= 0 ? 1 : 0);
    const int afterCount = after.u.list->num - (newIndex >= 0 ? 1 : 0);
    if (beforeCount != afterCount)
        return false;
    int a = 0;
    int b = 0;
    for (int count = 0; count < beforeCount; ++count) {
        if (a == oldIndex)
            ++a;
        if (b == newIndex)
            ++b;
        if (!equalNodes(before.u.list->values[a++], after.u.list->values[b++]))
            return false;
    }
    return true;
}

bool desiredReadback(const mpv_node &before, int oldIndex, const mpv_node &after, int preset) {
    if (!validAF(after))
        return false;
    const int index = ownedIndex(after);
    if (index == -2 || (preset == NORMAL ? index != -1
            : index < 0 || !matchesRecipe(after.u.list->values[index], preset)))
        return false;
    return customFiltersEqual(before, oldIndex, after, index);
}

Receipt rollback(MPVInstance *instance, NodeSnapshot &before, int64_t expected, jint observed) {
    mpv_handle *handle = instance->mpv;
    // No whole-chain write is safe once the expected loaded entry has gone away.
    if (!matchesEntry(handle, expected)) {
        instance->session_audio_preset_owned = NORMAL;
        return {ROLLBACK_FAILED, UNKNOWN};
    }
    const int status = mpv_set_property(handle, "af", MPV_FORMAT_NODE, before.data());
    NodeSnapshot restored;
    const bool verified = status >= 0 && restored.read(handle, "af") && validAF(restored.get()) &&
        equalNodes(before.get(), restored.get()) && matchesEntry(handle, expected);
    instance->session_audio_preset_owned = verified ? observed : NORMAL;
    return verified ? Receipt{REJECTED_RESTORED, observed} : Receipt{ROLLBACK_FAILED, UNKNOWN};
}

bool mutate(mpv_handle *handle, int oldIndex, int preset, int64_t expected) {
    if (oldIndex >= 0) {
        const char *remove[] = {"af", "remove", COMMAND_LABEL, nullptr};
        if (!matchesEntry(handle, expected) || mpv_command(handle, remove) < 0)
            return false;
    }
    if (preset != NORMAL) {
        const char *add[] = {"af", "add", preset == DIALOGUE ? DIALOGUE_FILTER : NIGHT_FILTER, nullptr};
        if (!matchesEntry(handle, expected) || mpv_command(handle, add) < 0)
            return false;
    }
    return true;
}

Receipt setPreset(MPVInstance *instance, int preset, int64_t expected) {
    if (!instance || !instance->mpv || preset < NORMAL || preset > NIGHT || expected < 0)
        return {UNAVAILABLE, UNKNOWN};
    mpv_handle *handle = instance->mpv;
    if (!matchesEntry(handle, expected))
        return {UNAVAILABLE, UNKNOWN};
    NodeSnapshot before;
    if (!before.read(handle, "af") || !validAF(before.get()))
        return {UNAVAILABLE, UNKNOWN};
    const int oldIndex = ownedIndex(before.get());
    const jint observed = observeOriginal(instance, before.get(), oldIndex);
    if (observed == UNKNOWN)
        return {UNAVAILABLE, UNKNOWN};
    if ((preset != NORMAL && !decodedPCMIntent(handle)) || !matchesEntry(handle, expected))
        return {UNAVAILABLE, observed};
    if (preset == observed)
        return {UNCHANGED, observed};
    if (!mutate(handle, oldIndex, preset, expected))
        return rollback(instance, before, expected, observed);
    NodeSnapshot after;
    const bool accepted = after.read(handle, "af") &&
        desiredReadback(before.get(), oldIndex, after.get(), preset) &&
        (preset == NORMAL || decodedPCMIntent(handle)) && matchesEntry(handle, expected);
    if (!accepted)
        return rollback(instance, before, expected, observed);
    instance->session_audio_preset_owned = preset;
    return {APPLIED, preset};
}

} // namespace

jni_func(jintArray, nativeSetSessionAudioPreset,
         jlong instance, jint preset, jlong expectedEntryID) {
    // Allocate the receipt before making any native change; OOM must not hide an accepted mutation.
    jintArray response = env->NewIntArray(2);
    if (!response)
        return nullptr;
    // This pointer comes only from nativeCreate and is protected by the caller's live handle lease.
    auto *mpvInstance = reinterpret_cast<MPVInstance *>(instance);
    const Receipt receipt = setPreset(mpvInstance, preset, static_cast<int64_t>(expectedEntryID));
    const jint values[] = {receipt.status, receipt.observed};
    env->SetIntArrayRegion(response, 0, 2, values);
    return response;
}
