#include "subtitle_reference.h"
#include "jni_utils.h"
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <cstdint>

namespace {
constexpr int MAX_FIELDS = 24;
constexpr int MAX_CUES = 1024;
constexpr int MAX_KEY_BYTES = 63;
constexpr int MAX_PAYLOAD = 9 * 1024 * 1024;

bool ascii_key(const char *key) {
    if (!key) return false;
    const size_t bytes = strnlen(key, MAX_KEY_BYTES + 1);
    if (!bytes || bytes > MAX_KEY_BYTES) return false;
    for (size_t i = 0; i < bytes; ++i)
        if (static_cast<unsigned char>(key[i]) < 0x21 || static_cast<unsigned char>(key[i]) > 0x7e)
            return false;
    return true;
}

bool utf8(const unsigned char *bytes, size_t count) {
    for (size_t i = 0; i < count;) {
        const unsigned char c = bytes[i++];
        if (!c) return false;
        if (c < 0x80) continue;
        unsigned remaining;
        uint32_t value, minimum;
        if (c >= 0xc2 && c <= 0xdf) { remaining = 1; value = c & 0x1f; minimum = 0x80; }
        else if (c >= 0xe0 && c <= 0xef) { remaining = 2; value = c & 0x0f; minimum = 0x800; }
        else if (c >= 0xf0 && c <= 0xf4) { remaining = 3; value = c & 7; minimum = 0x10000; }
        else return false;
        if (remaining > count - i) return false;
        while (remaining--) {
            const unsigned char next = bytes[i++];
            if ((next & 0xc0) != 0x80) return false;
            value = (value << 6) | (next & 0x3f);
        }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}

bool exact_revoke(const mpv_node &node) {
    if (node.format != MPV_FORMAT_NODE_MAP || !node.u.list || node.u.list->num != 2 ||
        !node.u.list->keys || !node.u.list->values) return false;
    bool version = false, released = false;
    for (int i = 0; i < 2; ++i) {
        const char *key = node.u.list->keys[i];
        const mpv_node &value = node.u.list->values[i];
        if (key && std::strcmp(key, "version") == 0 && !version &&
            value.format == MPV_FORMAT_INT64 && value.u.int64 == 2) version = true;
        else if (key && std::strcmp(key, "released") == 0 && !released &&
                 value.format == MPV_FORMAT_FLAG && (value.u.flag == 0 || value.u.flag == 1)) released = true;
        else return false;
    }
    return version && released; // both exact retirement and exact absence certify no further publication
}
} // namespace

jobject copy_reference_node(JNIEnv *env, const mpv_node *node) {
    if (!node || node->format != MPV_FORMAT_NODE_MAP || !node->u.list) return nullptr;
    const mpv_node_list *list = node->u.list;
    if (list->num < 1 || list->num > MAX_FIELDS || !list->keys || !list->values) return nullptr;
    jint formats[MAX_FIELDS]{};
    jlong integers[MAX_FIELDS]{};
    jdouble numbers[MAX_FIELDS]{};
    jlong pairs[MAX_CUES * 2]{};
    int pair_values = 0;
    for (int i = 0; i < list->num; ++i) {
        if (!ascii_key(list->keys[i])) return nullptr;
        for (int j = 0; j < i; ++j)
            if (std::strcmp(list->keys[i], list->keys[j]) == 0) return nullptr;
        const mpv_node &value = list->values[i];
        formats[i] = value.format;
        switch (value.format) {
        case MPV_FORMAT_INT64: integers[i] = value.u.int64; break;
        case MPV_FORMAT_DOUBLE:
            if (!std::isfinite(value.u.double_)) return nullptr;
            numbers[i] = value.u.double_; break;
        case MPV_FORMAT_FLAG:
            if (value.u.flag != 0 && value.u.flag != 1) return nullptr;
            integers[i] = value.u.flag; break;
        case MPV_FORMAT_NODE_ARRAY: {
            if (std::strcmp(list->keys[i], "cues") != 0 || pair_values || !value.u.list ||
                value.u.list->num < 1 || value.u.list->num > MAX_CUES || !value.u.list->values)
                return nullptr;
            for (int row = 0; row < value.u.list->num; ++row) {
                const mpv_node &item = value.u.list->values[row];
                if (item.format != MPV_FORMAT_NODE_ARRAY || !item.u.list || item.u.list->num != 2 ||
                    !item.u.list->values || item.u.list->values[0].format != MPV_FORMAT_INT64 ||
                    item.u.list->values[1].format != MPV_FORMAT_INT64) return nullptr;
                pairs[pair_values++] = item.u.list->values[0].u.int64;
                pairs[pair_values++] = item.u.list->values[1].u.int64;
            }
            break;
        }
        default: return nullptr; // no arbitrary nesting, strings, byte buffers or native pointers
        }
    }
    jobject result = nullptr;
    jclass strings = env->FindClass("java/lang/String");
    if (!strings) return nullptr;
    jobjectArray keys = nullptr;
    jintArray jf = nullptr;
    jlongArray ji = nullptr;
    jdoubleArray jn = nullptr;
    jlongArray jc = nullptr;
    if (!(keys = env->NewObjectArray(list->num, strings, nullptr))) goto cleanup;
    if (!(jf = env->NewIntArray(list->num))) goto cleanup;
    if (!(ji = env->NewLongArray(list->num))) goto cleanup;
    if (!(jn = env->NewDoubleArray(list->num))) goto cleanup;
    if (!(jc = env->NewLongArray(pair_values))) goto cleanup;
    if (keys && jf && ji && jn && jc && !env->ExceptionCheck()) {
        bool complete = true;
        for (int i = 0; i < list->num && !env->ExceptionCheck(); ++i) {
            jstring key = env->NewStringUTF(list->keys[i]);
            if (!key) { complete = false; break; }
            env->SetObjectArrayElement(keys, i, key);
            env->DeleteLocalRef(key);
        }
        if (complete && !env->ExceptionCheck()) {
            env->SetIntArrayRegion(jf, 0, list->num, formats);
            env->SetLongArrayRegion(ji, 0, list->num, integers);
            env->SetDoubleArrayRegion(jn, 0, list->num, numbers);
            if (pair_values) env->SetLongArrayRegion(jc, 0, pair_values, pairs);
            if (!env->ExceptionCheck()) result = env->NewObject(seam_MpvReferenceNode,
                seam_MpvReferenceNode_init, keys, jf, ji, jn, jc);
        }
    }
cleanup:
    if (jc) env->DeleteLocalRef(jc);
    if (jn) env->DeleteLocalRef(jn);
    if (ji) env->DeleteLocalRef(ji);
    if (jf) env->DeleteLocalRef(jf);
    if (keys) env->DeleteLocalRef(keys);
    env->DeleteLocalRef(strings);
    return result;
}

void send_reference_reply(JNIEnv *env, MPVInstance *instance, const mpv_event *event) {
    const auto *command = static_cast<const mpv_event_command *>(event->data);
    jobject node = event->error >= 0 && command ? copy_reference_node(env, &command->result) : nullptr;
    // A failed copy of a successful READ still may own a native grant. Preserve the original status;
    // Kotlin treats success-without-proof as unconfirmed and destroys the original context fail-closed.
    if (env->ExceptionCheck()) env->ExceptionClear();
    env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventReferenceReply_JIN,
        static_cast<jlong>(event->reply_userdata), static_cast<jint>(event->error), node);
    if (node) env->DeleteLocalRef(node);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        // Internal failure cannot silently strand the request's persistent handle lease.
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventReferenceFailure_J,
            static_cast<jlong>(event->reply_userdata));
        if (env->ExceptionCheck()) env->ExceptionClear(); // retain fail-closed lease on catastrophic VM failure
    }
}

extern "C" {
jni_func(jobject, nativeGetReferenceNode, jlong instance, jint property) {
    auto *owner = reinterpret_cast<MPVInstance *>(instance);
    if (!owner || !owner->mpv || (property != 0 && property != 1)) return nullptr;
    const char *name = property == 0 ? "vortx-subtitle-reference-capability" : "vortx-subtitle-reference-active";
    mpv_node node{};
    const int status = mpv_get_property(owner->mpv, name, MPV_FORMAT_NODE, &node);
    jobject result = status >= 0 ? copy_reference_node(env, &node) : nullptr;
    mpv_free_node_contents(&node);
    return result;
}

jni_func(jint, nativeBeginReference, jlong instance, jlong identifier, jint operation,
         jlongArray values, jdouble origin, jbyteArray payload) {
    auto *owner = reinterpret_cast<MPVInstance *>(instance);
    const int count = operation == 0 ? 7 : operation == 1 ? 9 : operation == 2 ? 10 : -1;
    if (!owner || !owner->mpv || identifier <= 0 || count < 0 || !values ||
        env->GetArrayLength(values) != count || !std::isfinite(origin) || std::abs(origin) > 86400)
        return MPV_ERROR_INVALID_PARAMETER;
    jlong ints[11]{};
    env->GetLongArrayRegion(values, 0, count, ints);
    if (env->ExceptionCheck()) { env->ExceptionClear(); return MPV_ERROR_INVALID_PARAMETER; }
    const int witness = operation == 0 ? 0 : operation == 1 ? 1 : 2;
    // READ has no source-generation field; PREPARE/COMMIT insert it after entry.
    const int extra = operation == 0 ? 0 : 1;
    for (int i = 0; i < witness; ++i) if (ints[i] <= 0) return MPV_ERROR_INVALID_PARAMETER;
    if (ints[witness] <= 0 || ints[witness + 1] <= 0) return MPV_ERROR_INVALID_PARAMETER;
    if (extra && ints[witness + 2] <= 0) return MPV_ERROR_INVALID_PARAMETER;
    const int ref = witness + 2 + extra;
    if (ints[ref] <= 0 || ints[ref] > INT32_MAX || ints[ref + 1] < 0 || ints[ref + 1] >= 128 ||
        ints[ref + 2] < 0 || ints[ref + 2] >= 1024 || ints[ref + 3] < 0 || ints[ref + 3] > INT32_MAX ||
        ints[ref + 4] < 0 || ints[ref + 4] > 3 ||
        (ints[ref + 3] == 0 && (ints[ref + 4] & 1))) return MPV_ERROR_INVALID_PARAMETER;
    char *text = nullptr;
    if (operation == 1) {
        if (!payload) return MPV_ERROR_INVALID_PARAMETER;
        const jsize bytes = env->GetArrayLength(payload);
        if (bytes < 1 || bytes > MAX_PAYLOAD) return MPV_ERROR_INVALID_PARAMETER;
        text = static_cast<char *>(std::malloc(static_cast<size_t>(bytes) + 1));
        if (!text) return MPV_ERROR_NOMEM;
        env->GetByteArrayRegion(payload, 0, bytes, reinterpret_cast<jbyte *>(text));
        if (env->ExceptionCheck()) { env->ExceptionClear(); std::free(text); return MPV_ERROR_NOMEM; }
        if (!utf8(reinterpret_cast<unsigned char *>(text), bytes)) { std::free(text); return MPV_ERROR_INVALID_PARAMETER; }
        text[bytes] = 0;
    } else if (payload) return MPV_ERROR_INVALID_PARAMETER;
    const char *names[] = {"vortx-subtitle-reference-read", "vortx-subtitle-reference-prepare", "vortx-subtitle-reference-commit"};
    mpv_node nodes[14]{};
    nodes[0].format = MPV_FORMAT_STRING;
    nodes[0].u.string = const_cast<char *>(names[operation]);
    for (int i = 0; i < count; ++i) { nodes[i + 1].format = MPV_FORMAT_INT64; nodes[i + 1].u.int64 = ints[i]; }
    nodes[count + 1].format = MPV_FORMAT_DOUBLE; nodes[count + 1].u.double_ = origin;
    if (text) { nodes[count + 2].format = MPV_FORMAT_STRING; nodes[count + 2].u.string = text; }
    mpv_node_list list{}; list.num = count + 2 + (text ? 1 : 0); list.values = nodes;
    mpv_node args{}; args.format = MPV_FORMAT_NODE_ARRAY; args.u.list = &list;
    const int status = mpv_command_node_async(owner->mpv, static_cast<uint64_t>(identifier), &args);
    std::free(text); // mpv copies/parses the command before its enqueue API returns
    return status;
}

jni_func(void, nativeAbortReference, jlong instance, jlong identifier) {
    auto *owner = reinterpret_cast<MPVInstance *>(instance);
    if (owner && owner->mpv && identifier > 0)
        mpv_abort_async_command(owner->mpv, static_cast<uint64_t>(identifier));
}

jni_func(jboolean, nativeRevokeReference, jlong instance, jlong grant) {
    auto *owner = reinterpret_cast<MPVInstance *>(instance);
    if (!owner || !owner->mpv || grant <= 0) return JNI_FALSE;
    mpv_node nodes[2]{};
    nodes[0].format = MPV_FORMAT_STRING;
    nodes[0].u.string = const_cast<char *>("vortx-subtitle-reference-revoke");
    nodes[1].format = MPV_FORMAT_INT64; nodes[1].u.int64 = grant;
    mpv_node_list list{}; list.num = 2; list.values = nodes;
    mpv_node args{}; args.format = MPV_FORMAT_NODE_ARRAY; args.u.list = &list;
    mpv_node result{};
    const int status = mpv_command_node(owner->mpv, &args, &result);
    const bool retired = status >= 0 && exact_revoke(result);
    mpv_free_node_contents(&result);
    return retired ? JNI_TRUE : JNI_FALSE;
}
} // extern "C"
