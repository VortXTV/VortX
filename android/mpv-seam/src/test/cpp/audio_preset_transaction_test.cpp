// Host regression harness. Compile this one translation unit, not audio_preset.cpp twice.
// The integrated production source is required below; only the mpv C API/fixture data are faked.
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <initializer_list>
#include <iostream>
#include <new>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <mpv/client.h>

#ifndef VORTX_AUDIO_PRESET_SOURCE
#error "Define VORTX_AUDIO_PRESET_SOURCE as the absolute integrated production source path"
#endif
#include VORTX_AUDIO_PRESET_SOURCE

namespace harness {

// Independent expected protocol bytes: an accidental production-recipe edit must not silently
// change the fake's accepted command or the expected readback graph along with it.
constexpr char kLabel[] = "vortx-session-audio-preset";
constexpr char kCommandLabel[] = "@vortx-session-audio-preset";
constexpr char kDialogueGraph[] =
    "equalizer=f=1800:t=q:w=1:g=3,alimiter=limit=0.95:level=0";
constexpr char kNightGraph[] =
    "acompressor=threshold=0.125:ratio=4:attack=20:release=250:makeup=1";
constexpr char kDialogueFilter[] =
    "@vortx-session-audio-preset:lavfi=[equalizer=f=1800:t=q:w=1:g=3,"
    "alimiter=limit=0.95:level=0]";
constexpr char kNightFilter[] =
    "@vortx-session-audio-preset:lavfi=[acompressor=threshold=0.125:ratio=4:"
    "attack=20:release=250:makeup=1]";
constexpr int64_t kEntry = INT64_C(41);

// Fixture storage owns values with STL. Exported C trees have separate allocations, just like
// mpv_get_property's copy contract; the fake free functions below own only those C allocations.
struct Value {
    mpv_format format = MPV_FORMAT_NONE;
    std::string text;
    int flag = 0;
    int64_t integer = 0;
    std::vector<std::string> keys;
    std::vector<Value> values;

    bool operator==(const Value &other) const {
        return format == other.format && text == other.text && flag == other.flag &&
            integer == other.integer && keys == other.keys && values == other.values;
    }
    bool operator!=(const Value &other) const { return !(*this == other); }
};

Value stringValue(std::string text) {
    Value value;
    value.format = MPV_FORMAT_STRING;
    value.text = std::move(text);
    return value;
}

Value flagValue(int flag) {
    Value value;
    value.format = MPV_FORMAT_FLAG;
    value.flag = flag;
    return value;
}

Value integerValue(int64_t integer) {
    Value value;
    value.format = MPV_FORMAT_INT64;
    value.integer = integer;
    return value;
}

Value mapValue(std::initializer_list<std::pair<std::string, Value>> entries) {
    Value value;
    value.format = MPV_FORMAT_NODE_MAP;
    value.keys.reserve(entries.size());
    value.values.reserve(entries.size());
    for (const auto &entry : entries) {
        value.keys.push_back(entry.first);
        value.values.push_back(entry.second);
    }
    return value;
}

Value arrayValue(std::initializer_list<Value> entries = {}) {
    Value value;
    value.format = MPV_FORMAT_NODE_ARRAY;
    value.values.assign(entries);
    return value;
}

Value *field(Value &map, const std::string &name) {
    for (size_t i = 0; i < map.keys.size(); ++i) {
        if (map.keys[i] == name)
            return &map.values[i];
    }
    return nullptr;
}

const Value *field(const Value &map, const std::string &name) {
    for (size_t i = 0; i < map.keys.size(); ++i) {
        if (map.keys[i] == name)
            return &map.values[i];
    }
    return nullptr;
}

Value customOne() {
    return mapValue({
        {"params", mapValue({{"z", stringValue("comma,colon:semicolon;[quoted]=yes")},
                              {"a", stringValue("01.000")}})},
        {"enabled", flagValue(0)},
        {"name", stringValue("custom-disabled")},
        {"label", stringValue("user-one")},
    });
}

Value customTwo() {
    return mapValue({
        {"name", stringValue("lavfi")},
        {"label", stringValue("user-two")},
        {"enabled", flagValue(1)},
        {"params", mapValue({{"graph", stringValue("volume=0.7")}})},
    });
}

Value customAF() { return arrayValue({customOne(), customTwo()}); }

Value ownedFilter(int preset, std::string graph = {}, int enabled = 1) {
    if (graph.empty())
        graph = preset == 1 ? kDialogueGraph : kNightGraph;
    return mapValue({
        {"name", stringValue("lavfi")},
        {"label", stringValue(kLabel)},
        {"enabled", flagValue(enabled)},
        {"params", mapValue({{"graph", stringValue(std::move(graph))}})},
    });
}

Value ownedAF(int preset) {
    // Owning an entry in the middle also exercises custom-chain array-order preservation.
    return arrayValue({customOne(), ownedFilter(preset), customTwo()});
}

void reverseMaps(Value &value) {
    for (auto &child : value.values)
        reverseMaps(child);
    if (value.format == MPV_FORMAT_NODE_MAP) {
        std::reverse(value.keys.begin(), value.keys.end());
        std::reverse(value.values.begin(), value.values.end());
    }
}

size_t outstandingCAllocations = 0;

void *allocateC(size_t bytes) {
    void *memory = std::calloc(1, bytes);
    if (!memory)
        throw std::bad_alloc();
    ++outstandingCAllocations;
    return memory;
}

void releaseC(void *memory) {
    if (!memory)
        return;
    if (outstandingCAllocations == 0)
        std::abort();
    --outstandingCAllocations;
    std::free(memory);
}

char *copyString(const std::string &text) {
    auto *copy = static_cast<char *>(allocateC(text.size() + 1));
    std::memcpy(copy, text.c_str(), text.size() + 1);
    return copy;
}

void exportNode(const Value &value, mpv_node &out) {
    out = {};
    out.format = value.format;
    switch (value.format) {
    case MPV_FORMAT_STRING:
        out.u.string = copyString(value.text);
        return;
    case MPV_FORMAT_FLAG:
        out.u.flag = value.flag;
        return;
    case MPV_FORMAT_INT64:
        out.u.int64 = value.integer;
        return;
    case MPV_FORMAT_NODE_ARRAY:
    case MPV_FORMAT_NODE_MAP: {
        auto *list = static_cast<mpv_node_list *>(allocateC(sizeof(mpv_node_list)));
        out.u.list = list;
        list->num = static_cast<int>(value.values.size());
        if (list->num == 0)
            return;
        list->values = static_cast<mpv_node *>(allocateC(sizeof(mpv_node) * value.values.size()));
        if (value.format == MPV_FORMAT_NODE_MAP)
            list->keys = static_cast<char **>(allocateC(sizeof(char *) * value.values.size()));
        for (size_t i = 0; i < value.values.size(); ++i) {
            exportNode(value.values[i], list->values[i]);
            if (value.format == MPV_FORMAT_NODE_MAP)
                list->keys[i] = copyString(value.keys.at(i));
        }
        return;
    }
    case MPV_FORMAT_NONE:
        return;
    default:
        throw std::runtime_error("fixture export does not implement this mpv format");
    }
}

Value importNode(const mpv_node &node) {
    Value value;
    value.format = node.format;
    switch (node.format) {
    case MPV_FORMAT_STRING:
        value.text = node.u.string;
        break;
    case MPV_FORMAT_FLAG:
        value.flag = node.u.flag;
        break;
    case MPV_FORMAT_INT64:
        value.integer = node.u.int64;
        break;
    case MPV_FORMAT_NODE_ARRAY:
    case MPV_FORMAT_NODE_MAP:
        for (int i = 0; i < node.u.list->num; ++i) {
            value.values.push_back(importNode(node.u.list->values[i]));
            if (node.format == MPV_FORMAT_NODE_MAP)
                value.keys.emplace_back(node.u.list->keys[i]);
        }
        break;
    default:
        throw std::runtime_error("fixture import does not implement this mpv format");
    }
    return value;
}

void require(bool condition, const char *expression, int line) {
    if (!condition)
        throw std::runtime_error(std::string("line ") + std::to_string(line) + ": " + expression);
}

#define CHECK(expression) ::harness::require(static_cast<bool>(expression), #expression, __LINE__)

} // namespace harness

// Complete only the client API's opaque fake handle. The production MPVInstance is never shadowed.
struct mpv_handle {
    harness::Value af = harness::customAF();
    std::string spdif;
    int64_t entry = harness::kEntry;
    int64_t position = 0;
    int afGets = 0;
    int allGets = 0;
    int spdifStringGets = 0;
    int commands = 0;
    int setCalls = 0;
    std::vector<std::string> commandNames;
    std::set<int> failAfGets;
    bool failRemove = false;
    bool partialRemoveFailure = false;
    bool failAdd = false;
    bool failSet = false;
    bool corruptRestore = false;
    bool wrongAddedGraph = false;
    bool alterCustomParamAfterAdd = false;
    bool reorderCustomAfterAdd = false;
    int reverseMapsAtAfGet = 0;
    int changeEntryAfterCommand = 0;
    int changeEntryAfterAfGet = 0;
    bool setPassthroughAfterAdd = false;
    bool overridePlaylist = false;
    harness::Value playlist;

    void finishCommand() {
        if (changeEntryAfterCommand == commands)
            ++entry;
    }
};

extern "C" {

int mpv_get_property(mpv_handle *ctx, const char *name, mpv_format format, void *data) {
    using namespace harness;
    ++ctx->allGets;
    const std::string property(name);
    if (property == "audio-spdif") {
        if (format == MPV_FORMAT_STRING) {
            ++ctx->spdifStringGets;
            *static_cast<char **>(data) = copyString(ctx->spdif);
            return 0;
        }
        if (format == MPV_FORMAT_NODE) {
            // Native audio-spdif is a string-list. Do not let a STRING-only fake hide this boundary.
            Value codecs = arrayValue();
            if (!ctx->spdif.empty())
                codecs.values.push_back(stringValue(ctx->spdif));
            exportNode(codecs, *static_cast<mpv_node *>(data));
            return 0;
        }
        return MPV_ERROR_PROPERTY_FORMAT;
    }
    if (format != MPV_FORMAT_NODE)
        return MPV_ERROR_PROPERTY_FORMAT;
    auto &out = *static_cast<mpv_node *>(data);
    if (property == "af") {
        ++ctx->afGets;
        if (ctx->failAfGets.count(ctx->afGets))
            return MPV_ERROR_PROPERTY_UNAVAILABLE;
        Value copy = ctx->af;
        if (ctx->reverseMapsAtAfGet > 0 && ctx->afGets >= ctx->reverseMapsAtAfGet)
            reverseMaps(copy);
        exportNode(copy, out);
        if (ctx->changeEntryAfterAfGet == ctx->afGets)
            ++ctx->entry;
        return 0;
    }
    if (property == "playlist-playing-pos") {
        exportNode(integerValue(ctx->position), out);
        return 0;
    }
    if (property == "playlist/" + std::to_string(ctx->position) + "/id" && ctx->position >= 0) {
        exportNode(integerValue(ctx->entry), out);
        return 0;
    }
    if (property == "playlist") {
        Value playlist = ctx->overridePlaylist ? ctx->playlist : arrayValue({mapValue({
            {"filename", stringValue("fixture-only; not a URL authority")},
            {"id", integerValue(ctx->entry)},
            {"playing", flagValue(1)},
        })});
        exportNode(playlist, out);
        return 0;
    }
    return MPV_ERROR_PROPERTY_NOT_FOUND;
}

int mpv_set_property(mpv_handle *ctx, const char *name, mpv_format format, void *data) {
    using namespace harness;
    ++ctx->setCalls;
    if (std::strcmp(name, "af") != 0 || format != MPV_FORMAT_NODE)
        return MPV_ERROR_PROPERTY_FORMAT;
    if (ctx->failSet)
        return MPV_ERROR_PROPERTY_ERROR;
    ctx->af = importNode(*static_cast<mpv_node *>(data));
    if (ctx->corruptRestore && !ctx->af.values.empty())
        field(ctx->af.values.front(), "name")->text = "unexpected-restored-filter";
    return 0;
}

int mpv_command(mpv_handle *ctx, const char **args) {
    using namespace harness;
    ++ctx->commands;
    if (!args || !args[0] || !args[1] || !args[2] || args[3] ||
        std::strcmp(args[0], "af") != 0)
        return MPV_ERROR_COMMAND;
    ctx->commandNames.emplace_back(args[1]);
    if (std::strcmp(args[1], "remove") == 0 && std::strcmp(args[2], kCommandLabel) == 0) {
        if (ctx->failRemove && !ctx->partialRemoveFailure)
            return MPV_ERROR_COMMAND;
        const auto owned = std::find_if(ctx->af.values.begin(), ctx->af.values.end(), [](const Value &v) {
            const Value *label = field(v, "label");
            return label && label->text == kLabel;
        });
        if (owned == ctx->af.values.end())
            return MPV_ERROR_COMMAND;
        ctx->af.values.erase(owned);
        ctx->finishCommand();
        return ctx->failRemove ? MPV_ERROR_COMMAND : 0;
    }
    const bool dialogue = std::strcmp(args[2], kDialogueFilter) == 0;
    const bool night = std::strcmp(args[2], kNightFilter) == 0;
    if (std::strcmp(args[1], "add") != 0 || (!dialogue && !night) || ctx->failAdd)
        return MPV_ERROR_COMMAND;
    ctx->af.values.push_back(ownedFilter(dialogue ? 1 : 2,
        ctx->wrongAddedGraph ? "volume=100" : ""));
    if (ctx->alterCustomParamAfterAdd && !ctx->af.values.empty()) {
        Value *params = field(ctx->af.values.front(), "params");
        if (params && !params->values.empty())
            params->values.front().text = "changed-custom-value";
    }
    if (ctx->reorderCustomAfterAdd && ctx->af.values.size() >= 3)
        std::swap(ctx->af.values[0], ctx->af.values[1]);
    if (ctx->setPassthroughAfterAdd)
        ctx->spdif = "ac3,dts";
    ctx->finishCommand();
    return 0;
}

void mpv_free_node_contents(mpv_node *node) {
    using namespace harness;
    if (!node)
        return;
    if (node->format == MPV_FORMAT_STRING) {
        releaseC(node->u.string);
    } else if (node->format == MPV_FORMAT_NODE_ARRAY || node->format == MPV_FORMAT_NODE_MAP) {
        mpv_node_list *list = node->u.list;
        if (list) {
            for (int i = 0; i < list->num; ++i) {
                mpv_free_node_contents(&list->values[i]);
                if (node->format == MPV_FORMAT_NODE_MAP)
                    releaseC(list->keys[i]);
            }
            releaseC(list->values);
            // ARRAY keys are unused; don't inspect them, mirroring the bundled client contract.
            if (node->format == MPV_FORMAT_NODE_MAP)
                releaseC(list->keys);
            releaseC(list);
        }
    }
    *node = {};
}

void mpv_free(void *data) { harness::releaseC(data); }

} // extern "C"

namespace harness {

struct Session {
    mpv_handle core;
    MPVInstance instance{};

    explicit Session(Value af = customAF(), int witness = NORMAL) {
        core.af = std::move(af);
        instance.mpv = &core;
        // This is the real companion field. Compilation deliberately requires real globals.h.
        instance.session_audio_preset_owned = witness;
    }

    Receipt apply(int preset, int64_t expected = kEntry) {
        return setPreset(&instance, preset, expected);
    }
};

void expectReceipt(const Receipt &receipt, jint status, jint observed) {
    CHECK(receipt.status == status);
    CHECK(receipt.observed == observed);
}

void afGetRejectionHasNoMutation() {
    Session s;
    const Value before = s.core.af;
    s.core.failAfGets.insert(1);
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.commands == 0 && s.core.setCalls == 0 && s.core.af == before);
}

void malformedInputsHaveNoReadsOrMutation() {
    for (int preset : {-1, 3}) {
        Session s;
        expectReceipt(s.apply(preset), UNAVAILABLE, UNKNOWN);
        CHECK(s.core.allGets == 0 && s.core.commands == 0 && s.core.setCalls == 0);
    }
    Session s;
    expectReceipt(s.apply(DIALOGUE, -1), UNAVAILABLE, UNKNOWN);
    expectReceipt(setPreset(nullptr, DIALOGUE, kEntry), UNAVAILABLE, UNKNOWN);
    s.instance.mpv = nullptr;
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.allGets == 0);
}

void initialEntryMismatchHasNoAfReadOrMutation() {
    Session s;
    expectReceipt(s.apply(DIALOGUE, kEntry + 1), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.afGets == 0 && s.core.commands == 0 && s.core.setCalls == 0);
}

void coherentPlaylistRejectsMismatchedPlayingId() {
    Session s;
    s.core.overridePlaylist = true;
    s.core.playlist = arrayValue({mapValue({{"id", integerValue(kEntry + 1)},
                                           {"playing", flagValue(1)}})});
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.afGets == 0 && s.core.commands == 0 && s.core.setCalls == 0);
}

void coherentPlaylistRejectsDuplicatePlayingEntries() {
    Session s;
    s.core.overridePlaylist = true;
    const Value entry = mapValue({{"id", integerValue(kEntry)}, {"playing", flagValue(1)}});
    s.core.playlist = arrayValue({entry, entry});
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.afGets == 0 && s.core.commands == 0);
}

void entryIdentityStaysInt64() {
    Session s;
    s.core.entry = (INT64_C(1) << 40) + 41;
    expectReceipt(s.apply(DIALOGUE, s.core.entry), APPLIED, DIALOGUE);
    CHECK(s.core.commands == 1 && s.instance.session_audio_preset_owned == DIALOGUE);
}

void passthroughRejectsWithoutChangingChain() {
    Session s;
    const Value before = s.core.af;
    s.core.spdif = "ac3,dts,eac3";
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, NORMAL);
    CHECK(s.core.spdifStringGets == 1 && s.core.commands == 0 && s.core.setCalls == 0);
    CHECK(s.core.af == before && s.core.spdif == "ac3,dts,eac3");
}

void unchangedNormalPreservesNonemptyCustomChain() {
    Session s;
    const Value before = s.core.af;
    s.core.spdif = "ac3"; // Normal must still be available to remove a previously owned filter.
    expectReceipt(s.apply(NORMAL), UNCHANGED, NORMAL);
    CHECK(s.core.commands == 0 && s.core.setCalls == 0 && s.core.af == before);
}

void applyPreservesTypedCustomParamsAndArrayOrder() {
    Session s;
    const Value before = s.core.af;
    expectReceipt(s.apply(DIALOGUE), APPLIED, DIALOGUE);
    CHECK(s.core.commands == 1 && s.core.setCalls == 0 && s.core.af.values.size() == 3);
    CHECK(s.core.af.values[0] == before.values[0] && s.core.af.values[1] == before.values[1]);
    CHECK(s.core.af.values[2] == ownedFilter(DIALOGUE));
    CHECK(s.instance.session_audio_preset_owned == DIALOGUE);
}

void readbackMapOrderIsNotIdentity() {
    Session s;
    s.core.reverseMapsAtAfGet = 2; // Only post-mutation readback has reversed MAP key order.
    expectReceipt(s.apply(DIALOGUE), APPLIED, DIALOGUE);
    CHECK(s.core.setCalls == 0 && s.core.commands == 1);
}

void unchangedOwnedRecipeNeedsNoCommand() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    const Value before = s.core.af;
    expectReceipt(s.apply(DIALOGUE), UNCHANGED, DIALOGUE);
    CHECK(s.core.af == before && s.core.commands == 0 && s.core.setCalls == 0);
}

void normalRemovesOnlyOwnedFilter() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    expectReceipt(s.apply(NORMAL), APPLIED, NORMAL);
    CHECK(s.core.af == customAF() && s.core.commands == 1 && s.core.setCalls == 0);
    CHECK(s.instance.session_audio_preset_owned == NORMAL);
}

void removeFailureRestoresExactOriginal() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    const Value before = s.core.af;
    s.core.failRemove = true;
    expectReceipt(s.apply(NIGHT), REJECTED_RESTORED, DIALOGUE);
    CHECK(s.core.af == before && s.core.commands == 1 && s.core.setCalls == 1);
    CHECK(s.instance.session_audio_preset_owned == DIALOGUE);
}

void partialRemoveFailureAlsoRestoresExactOriginal() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    const Value before = s.core.af;
    s.core.failRemove = true;
    s.core.partialRemoveFailure = true;
    expectReceipt(s.apply(NIGHT), REJECTED_RESTORED, DIALOGUE);
    CHECK(s.core.af == before && s.core.commands == 1 && s.core.setCalls == 1);
}

void addFailureAfterRemoveRestoresExactOriginal() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    const Value before = s.core.af;
    s.core.failAdd = true;
    expectReceipt(s.apply(NIGHT), REJECTED_RESTORED, DIALOGUE);
    CHECK(s.core.af == before && s.core.commands == 2 && s.core.setCalls == 1);
    CHECK(s.core.commandNames == std::vector<std::string>({"remove", "add"}));
}

void addFailureFromNormalRestoresCustomChain() {
    Session s;
    const Value before = s.core.af;
    s.core.failAdd = true;
    expectReceipt(s.apply(NIGHT), REJECTED_RESTORED, NORMAL);
    CHECK(s.core.af == before && s.core.commands == 1 && s.core.setCalls == 1);
}

void rollbackSetFailureIsUnknownAndRevokesWitness() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    s.core.failAdd = true;
    s.core.failSet = true;
    expectReceipt(s.apply(NIGHT), ROLLBACK_FAILED, UNKNOWN);
    CHECK(s.core.setCalls == 1 && s.instance.session_audio_preset_owned == NORMAL);
}

void rollbackReadbackFailureIsUnknownEvenIfBytesRestored() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    const Value before = s.core.af;
    s.core.failAdd = true;
    s.core.failAfGets.insert(2);
    expectReceipt(s.apply(NIGHT), ROLLBACK_FAILED, UNKNOWN);
    CHECK(s.core.af == before && s.core.setCalls == 1);
    CHECK(s.instance.session_audio_preset_owned == NORMAL);
}

void rollbackReadbackMismatchIsUnknown() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    s.core.failAdd = true;
    s.core.corruptRestore = true;
    expectReceipt(s.apply(NIGHT), ROLLBACK_FAILED, UNKNOWN);
    CHECK(s.core.setCalls == 1 && s.instance.session_audio_preset_owned == NORMAL);
}

void entryChangeAfterRemoveStopsAddAndCrossEntryRestore() {
    Session s(ownedAF(DIALOGUE), DIALOGUE);
    s.core.changeEntryAfterCommand = 1;
    expectReceipt(s.apply(NIGHT), ROLLBACK_FAILED, UNKNOWN);
    CHECK(s.core.commands == 1 && s.core.setCalls == 0 && s.core.entry == kEntry + 1);
    CHECK(s.core.af == customAF() && s.instance.session_audio_preset_owned == NORMAL);
}

void entryChangeAfterAddDoesNotRestoreOldEntrySnapshot() {
    Session s;
    s.core.changeEntryAfterCommand = 1;
    expectReceipt(s.apply(DIALOGUE), ROLLBACK_FAILED, UNKNOWN);
    CHECK(s.core.commands == 1 && s.core.setCalls == 0 && s.core.entry == kEntry + 1);
    CHECK(s.instance.session_audio_preset_owned == NORMAL);
}

void entryChangeAfterInitialAfReadDoesNotStartCommand() {
    Session s;
    s.core.changeEntryAfterAfGet = 1;
    expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, NORMAL);
    CHECK(s.core.commands == 0 && s.core.setCalls == 0);
}

void desiredGraphMismatchRestoresExactCustomChain() {
    Session s;
    const Value before = s.core.af;
    s.core.wrongAddedGraph = true;
    expectReceipt(s.apply(DIALOGUE), REJECTED_RESTORED, NORMAL);
    CHECK(s.core.af == before && s.core.commands == 1 && s.core.setCalls == 1);
}

void customParamChangeIsDetectedAndRestored() {
    Session s;
    const Value before = s.core.af;
    s.core.alterCustomParamAfterAdd = true;
    expectReceipt(s.apply(DIALOGUE), REJECTED_RESTORED, NORMAL);
    CHECK(s.core.af == before && s.core.setCalls == 1);
}

void customArrayReorderIsDetectedAndRestored() {
    Session s;
    const Value before = s.core.af;
    s.core.reorderCustomAfterAdd = true;
    expectReceipt(s.apply(DIALOGUE), REJECTED_RESTORED, NORMAL);
    CHECK(s.core.af == before && s.core.setCalls == 1);
}

void passthroughChangeAfterAddCannotBeAccepted() {
    Session s;
    const Value before = s.core.af;
    s.core.setPassthroughAfterAdd = true;
    expectReceipt(s.apply(DIALOGUE), REJECTED_RESTORED, NORMAL);
    CHECK(s.core.af == before && s.core.spdif == "ac3,dts" && s.core.setCalls == 1);
}

void matchingForeignRecipeIsNotOwnership() {
    Session s(ownedAF(DIALOGUE), NORMAL);
    const Value before = s.core.af;
    expectReceipt(s.apply(NORMAL), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.af == before && s.core.commands == 0 && s.core.setCalls == 0);
}

void revokedWitnessProtectsIdenticalRecipeFromRemoval() {
    Session s;
    expectReceipt(s.apply(DIALOGUE), APPLIED, DIALOGUE);
    const Value before = s.core.af;
    // Simulates the companion generic-writer guard's effect, not its implementation. This TU
    // does NOT claim to test nativeCommand/nativeSetPropertyString or their revocation coverage.
    s.instance.session_audio_preset_owned = NORMAL;
    s.core.commands = 0;
    expectReceipt(s.apply(NORMAL), UNAVAILABLE, UNKNOWN);
    CHECK(s.core.af == before && s.core.commands == 0 && s.core.setCalls == 0);
}

void invalidReservedLabelsRevokeWitnessWithoutMutation() {
    for (int variant = 0; variant < 3; ++variant) {
        Value af = ownedAF(DIALOGUE);
        if (variant == 0)
            af.values.push_back(ownedFilter(DIALOGUE)); // Duplicate reserved label.
        if (variant == 1)
            af.values[1] = ownedFilter(DIALOGUE, "volume=1");
        if (variant == 2)
            af.values[1] = ownedFilter(DIALOGUE, {}, 0);
        Session s(af, DIALOGUE);
        expectReceipt(s.apply(NORMAL), UNAVAILABLE, UNKNOWN);
        CHECK(s.core.af == af && s.core.commands == 0 && s.core.setCalls == 0);
        CHECK(s.instance.session_audio_preset_owned == NORMAL);
    }
}

void absentLabelRetiresStaleWitness() {
    Session s(customAF(), DIALOGUE);
    expectReceipt(s.apply(NORMAL), UNCHANGED, NORMAL);
    CHECK(s.instance.session_audio_preset_owned == NORMAL && s.core.commands == 0);
}

void unsupportedAfShapesRejectBeforeMutation() {
    for (int variant = 0; variant < 3; ++variant) {
        Value filter = mapValue({{"name", stringValue("custom")},
                                 {"enabled", flagValue(1)}, {"params", mapValue({})}});
        if (variant == 0) {
            filter.keys.push_back("future-field"); // Four entries: tests the unknown-key branch.
            filter.values.push_back(stringValue("must not be lost during rollback"));
        } else if (variant == 1) {
            *field(filter, "params") = mapValue({{"number", integerValue(42)}});
        } else {
            filter.keys.push_back("name");
            filter.values.push_back(stringValue("duplicate"));
        }
        Session s(arrayValue({filter}));
        const Value before = s.core.af;
        expectReceipt(s.apply(DIALOGUE), UNAVAILABLE, UNKNOWN);
        CHECK(s.core.af == before && s.core.commands == 0 && s.core.setCalls == 0);
    }
}

} // namespace harness

int main() {
    using namespace harness;
    struct Test { const char *name; void (*body)(); };
    const Test cases[] = {
        {"AF-get rejection", afGetRejectionHasNoMutation},
        {"malformed inputs", malformedInputsHaveNoReadsOrMutation},
        {"initial entry mismatch", initialEntryMismatchHasNoAfReadOrMutation},
        {"coherent playing ID mismatch", coherentPlaylistRejectsMismatchedPlayingId},
        {"duplicate playing entries", coherentPlaylistRejectsDuplicatePlayingEntries},
        {"64-bit entry identity", entryIdentityStaysInt64},
        {"passthrough refusal", passthroughRejectsWithoutChangingChain},
        {"Normal unchanged", unchangedNormalPreservesNonemptyCustomChain},
        {"custom typed params/order preserved", applyPreservesTypedCustomParamsAndArrayOrder},
        {"MAP order ignored", readbackMapOrderIsNotIdentity},
        {"owned recipe unchanged", unchangedOwnedRecipeNeedsNoCommand},
        {"Normal removes only ours", normalRemovesOnlyOwnedFilter},
        {"remove failure rollback", removeFailureRestoresExactOriginal},
        {"partial remove failure rollback", partialRemoveFailureAlsoRestoresExactOriginal},
        {"add failure after remove rollback", addFailureAfterRemoveRestoresExactOriginal},
        {"add failure from Normal rollback", addFailureFromNormalRestoresCustomChain},
        {"rollback set failure", rollbackSetFailureIsUnknownAndRevokesWitness},
        {"rollback get failure", rollbackReadbackFailureIsUnknownEvenIfBytesRestored},
        {"rollback readback mismatch", rollbackReadbackMismatchIsUnknown},
        {"entry changes after remove", entryChangeAfterRemoveStopsAddAndCrossEntryRestore},
        {"entry changes after add", entryChangeAfterAddDoesNotRestoreOldEntrySnapshot},
        {"entry changes before command", entryChangeAfterInitialAfReadDoesNotStartCommand},
        {"desired graph mismatch", desiredGraphMismatchRestoresExactCustomChain},
        {"custom param mutation detected", customParamChangeIsDetectedAndRestored},
        {"custom array reorder detected", customArrayReorderIsDetectedAndRestored},
        {"passthrough changes after add", passthroughChangeAfterAddCannotBeAccepted},
        {"foreign exact recipe collision", matchingForeignRecipeIsNotOwnership},
        {"revoked witness blocks removal", revokedWitnessProtectsIdenticalRecipeFromRemoval},
        {"invalid reserved label variants", invalidReservedLabelsRevokeWitnessWithoutMutation},
        {"absent label clears witness", absentLabelRetiresStaleWitness},
        {"unsupported AF shape variants", unsupportedAfShapesRejectBeforeMutation},
    };
    int failed = 0;
    for (const auto &test : cases) {
        try {
            test.body();
            CHECK(outstandingCAllocations == 0);
            std::cout << "PASS " << test.name << '\n';
        } catch (const std::exception &error) {
            ++failed;
            std::cerr << "FAIL " << test.name << ": " << error.what() << '\n';
            if (outstandingCAllocations != 0)
                std::cerr << "  outstanding fake-mpv C allocations: " << outstandingCAllocations << '\n';
        }
    }
    std::cout << (sizeof(cases) / sizeof(cases[0])) << " cases, " << failed << " failures\n";
    return failed == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
