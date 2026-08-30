// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/render.cpp.
// Renamed to the VortX seam JNI symbol prefix. Rendering stays on mpv's own Android output: the
// attached Surface's global ref is handed to mpv as the `wid` option and mpv converts it via the JVM
// registered by av_jni_set_java_vm (see main.cpp prepare_environment). VortX additionally makes
// replacement and removal idempotent so repeated SurfaceHolder callbacks cannot leak or double-delete.
#include <jni.h>

#include <mpv/client.h>

#include "jni_utils.h"
#include "log.h"
#include "globals.h"

extern "C" {
    jni_func(jint, nativeAttachSurface, jlong instance, jobject surface);
    jni_func(jint, nativeDetachSurface, jlong instance);
}

jni_func(jint, nativeAttachSurface, jlong instance, jobject surface) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);

    // Build the replacement ref first. The old ref remains valid until mpv has accepted the new wid,
    // so a repeated SurfaceHolder attach can never leak the previous surface or leave mpv pointing at
    // a deleted JNI reference.
    jobject replacement = env->NewGlobalRef(surface);
    if (!replacement) {
        die(env, "invalid surface provided");
        return MPV_ERROR_NOMEM;
    }

    int64_t wid = reinterpret_cast<intptr_t>(replacement);
    int result = mpv_set_option(mpv_instance->mpv, "wid", MPV_FORMAT_INT64, &wid);
    if (result < 0) {
        ALOGE("mpv_set_option(wid) returned error %s", mpv_error_string(result));
        env->DeleteGlobalRef(replacement);
        return result;
    }

    if (mpv_instance->surface)
        env->DeleteGlobalRef(mpv_instance->surface);
    mpv_instance->surface = replacement;
    return MPV_ERROR_SUCCESS;
}

jni_func(jint, nativeDetachSurface, jlong instance) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->surface)
        return MPV_ERROR_SUCCESS;

    int64_t wid = 0;
    int result = mpv_set_option(mpv_instance->mpv, "wid", MPV_FORMAT_INT64, &wid);
    if (result < 0) {
        ALOGE("mpv_set_option(wid) returned error %s", mpv_error_string(result));
        return result;
    }

    env->DeleteGlobalRef(mpv_instance->surface);
    mpv_instance->surface = nullptr;
    return MPV_ERROR_SUCCESS;
}
