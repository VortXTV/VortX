// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/render.cpp.
// Renamed to the VortX seam JNI symbol prefix; no behavioral change vs upstream. Rendering stays on
// mpv's own Android output: the attached Surface's global ref is handed to mpv as the `wid` option and
// mpv converts it via the JVM registered by av_jni_set_java_vm (see main.cpp prepare_environment).
#include <jni.h>

#include <mpv/client.h>

#include "jni_utils.h"
#include "log.h"
#include "globals.h"

extern "C" {
    jni_func(void, nativeAttachSurface, jlong instance, jobject surface);
    jni_func(void, nativeDetachSurface, jlong instance);
}

jni_func(void, nativeAttachSurface, jlong instance, jobject surface) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);

    mpv_instance->surface = env->NewGlobalRef(surface);
    if (!mpv_instance->surface) {
        die(env, "invalid surface provided");
        return;
    }

    int64_t wid = reinterpret_cast<intptr_t>(mpv_instance->surface);
    int result = mpv_set_option(mpv_instance->mpv, "wid", MPV_FORMAT_INT64, &wid);
    if (result < 0)
        ALOGE("mpv_set_option(wid) returned error %s", mpv_error_string(result));
}

jni_func(void, nativeDetachSurface, jlong instance) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    int64_t wid = 0;
    int result = mpv_set_option(mpv_instance->mpv, "wid", MPV_FORMAT_INT64, &wid);
    if (result < 0)
        ALOGE("mpv_set_option(wid) returned error %s", mpv_error_string(result));

    env->DeleteGlobalRef(mpv_instance->surface);
    mpv_instance->surface = nullptr;
}
