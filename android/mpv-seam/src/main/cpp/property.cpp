// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file
// libmpv/src/main/cpp/property.cpp. Renamed to the VortX seam JNI symbol prefix; no behavioral
// change vs upstream.
#include <jni.h>
#include <cstdlib>

#include <mpv/client.h>

#include "jni_utils.h"
#include "log.h"
#include "globals.h"

extern "C" {
    jni_func(jint, nativeSetOptionString, jlong instance, jstring joption, jstring jvalue);

    jni_func(jobject, nativeGetPropertyInt, jlong instance, jstring jproperty);
    jni_func(void, nativeSetPropertyInt, jlong instance, jstring jproperty, jint jvalue);
    jni_func(jobject, nativeGetPropertyDouble, jlong instance, jstring jproperty);
    jni_func(void, nativeSetPropertyDouble, jlong instance, jstring jproperty, jdouble jvalue);
    jni_func(jobject, nativeGetPropertyBoolean, jlong instance, jstring jproperty);
    jni_func(void, nativeSetPropertyBoolean, jlong instance, jstring jproperty, jboolean jvalue);
    jni_func(jstring, nativeGetPropertyString, jlong instance, jstring jproperty);
    jni_func(void, nativeSetPropertyString, jlong instance, jstring jproperty, jstring jvalue);

    jni_func(void, nativeObserveProperty, jlong instance, jstring jproperty, jint jformat);
}

jni_func(jint, nativeSetOptionString, jlong instance, jstring joption, jstring jvalue) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->mpv) {
        die(env, "mpv is not initialized");
        return 0;
    }

    const char *option = env->GetStringUTFChars(joption, nullptr);
    const char *value = env->GetStringUTFChars(jvalue, nullptr);

    int result = mpv_set_option_string(mpv_instance->mpv, option, value);

    env->ReleaseStringUTFChars(joption, option);
    env->ReleaseStringUTFChars(jvalue, value);

    return result;
}

static int common_get_property(JNIEnv *env, mpv_handle* mpv, jstring jproperty, mpv_format format, void *output) {
    if (!mpv) {
        die(env, "get_property called but mpv is not initialized");
        return -1;
    }

    const char *prop = env->GetStringUTFChars(jproperty, nullptr);
    int result = mpv_get_property(mpv, prop, format, output);
    if (result < 0)
        ALOGE("mpv_get_property(%s) format %d returned error %s", prop, format, mpv_error_string(result));
    env->ReleaseStringUTFChars(jproperty, prop);

    return result;
}

static int common_set_property(JNIEnv *env, mpv_handle* mpv, jstring jproperty, mpv_format format, void *value) {
    if (!mpv) {
        die(env, "set_property called but mpv is not initialized");
        return -1;
    }

    const char *prop = env->GetStringUTFChars(jproperty, nullptr);
    int result = mpv_set_property(mpv, prop, format, value);
    if (result < 0)
        ALOGE("mpv_set_property(%s, %p) format %d returned error %s", prop, value, format, mpv_error_string(result));
    env->ReleaseStringUTFChars(jproperty, prop);

    return result;
}

jni_func(jobject, nativeGetPropertyInt, jlong instance, jstring jproperty) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    int64_t value = 0;
    if (common_get_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_INT64, &value) < 0)
        return nullptr;
    return env->NewObject(java_Integer, java_Integer_init, (jint)value);
}

jni_func(jobject, nativeGetPropertyDouble, jlong instance, jstring jproperty) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    double value = 0;
    if (common_get_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_DOUBLE, &value) < 0)
        return nullptr;
    return env->NewObject(java_Double, java_Double_init, (jdouble)value);
}

jni_func(jobject, nativeGetPropertyBoolean, jlong instance, jstring jproperty) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    int value = 0;
    if (common_get_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_FLAG, &value) < 0)
        return nullptr;
    return env->NewObject(java_Boolean, java_Boolean_init, (jboolean)value);
}

jni_func(jstring, nativeGetPropertyString, jlong instance, jstring jproperty) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    char *value;
    if (common_get_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_STRING, &value) < 0)
        return nullptr;
    jstring jvalue = env->NewStringUTF(value);
    mpv_free(value);
    return jvalue;
}

jni_func(void, nativeSetPropertyInt, jlong instance, jstring jproperty, jint jvalue) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    int64_t value = static_cast<int64_t>(jvalue);
    common_set_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_INT64, &value);
}

jni_func(void, nativeSetPropertyDouble, jlong instance, jstring jproperty, jdouble jvalue) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    double value = static_cast<double>(jvalue);
    common_set_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_DOUBLE, &value);
}

jni_func(void, nativeSetPropertyBoolean, jlong instance, jstring jproperty, jboolean jvalue) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    int value = jvalue == JNI_TRUE ? 1 : 0;
    common_set_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_FLAG, &value);
}

jni_func(void, nativeSetPropertyString, jlong instance, jstring jproperty, jstring jvalue) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    const char *value = env->GetStringUTFChars(jvalue, nullptr);
    common_set_property(env, mpv_instance->mpv, jproperty, MPV_FORMAT_STRING, &value);
    env->ReleaseStringUTFChars(jvalue, value);
}

jni_func(void, nativeObserveProperty, jlong instance, jstring jproperty, jint jformat) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->mpv) {
        die(env, "mpv is not initialized");
        return;
    }

    const char *prop = env->GetStringUTFChars(jproperty, nullptr);
    int result = mpv_observe_property(mpv_instance->mpv, 0, prop, (mpv_format)jformat);
    if (result < 0)
        ALOGE("mpv_observe_property(%s) format %d returned error %s", prop, jformat, mpv_error_string(result));
    env->ReleaseStringUTFChars(jproperty, prop);
}
