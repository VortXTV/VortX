// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/main.cpp.
// Renamed to the VortX seam JNI symbol prefix. VortX additionally cleans partial creation and keeps
// final surface ownership inside native destruction so Java teardown cannot race a freed instance.
#include <jni.h>
#include <cstdlib>
#include <cstdio>
#include <ctime>
#include <clocale>
#include <atomic>
#include <thread>

#include <mpv/client.h>

#include <pthread.h>

extern "C" {
    // Upstream includes <libavcodec/jni.h> for these two. That is an FFmpeg (LGPL) header we do not
    // vendor, so the two symbols prepare_environment() uses are declared here with their EXACT
    // FFmpeg 8.1 prototypes (libavcodec/jni.h) instead; they link from this build's libavcodec.so.
    int av_jni_set_java_vm(void *vm, void *log_ctx);
    int av_jni_set_android_app_ctx(void *app_ctx, void *log_ctx);
}

#include "log.h"
#include "jni_utils.h"
#include "event.h"
#include "globals.h"

#define ARRAYLEN(a) (sizeof(a)/sizeof(a[0]))

// Update the JNI functions to accept a jlong parameter, which will be a
// pointer to the MPVInstance
extern "C" {
    jni_func(jlong, nativeCreate, jobject thiz, jobject appctx);
    jni_func(void, nativeInit, jlong instance);
    jni_func(void, nativeDestroy, jlong instance);
    jni_func(void, nativeCommand, jlong instance, jobjectArray jarray);
};

static void prepare_environment(JNIEnv *env, MPVInstance* instance) {
    setlocale(LC_NUMERIC, "C");

    if (env->GetJavaVM(&instance->vm) == JNI_OK && instance->vm)
        av_jni_set_java_vm(instance->vm, nullptr);

    if (instance->appCtx)
        av_jni_set_android_app_ctx(instance->appCtx, nullptr);

    init_methods_cache(env);
}

void finalize_mpv_instance(JNIEnv *env, MPVInstance *instance) {
    if (instance->mpv) {
        mpv_terminate_destroy(instance->mpv);
        instance->mpv = nullptr;
    }
    if (instance->surface) {
        env->DeleteGlobalRef(instance->surface);
        instance->surface = nullptr;
    }
    if (instance->appCtx) {
        env->DeleteGlobalRef(instance->appCtx);
        instance->appCtx = nullptr;
    }
    if (instance->javaObject) {
        env->DeleteGlobalRef(instance->javaObject);
        instance->javaObject = nullptr;
    }
    delete instance;
}

jni_func(jlong, nativeCreate, jobject thiz, jobject appctx) {
    auto instance = new MPVInstance();
    instance->event_thread_id = 0;
    instance->event_thread_request_exit = false;
    instance->teardown_request_complete = false;
    instance->event_thread_start_state = EVENT_THREAD_STARTING;
    instance->mpv = nullptr;
    instance->vm = nullptr;
    instance->surface = nullptr;
    instance->javaObject = env->NewGlobalRef(thiz);
    instance->appCtx = env->NewGlobalRef(appctx);
    if (!instance->javaObject || !instance->appCtx) {
        if (instance->appCtx)
            env->DeleteGlobalRef(instance->appCtx);
        if (instance->javaObject)
            env->DeleteGlobalRef(instance->javaObject);
        delete instance;
        return 0;
    }
    prepare_environment(env, instance);

    instance->mpv = mpv_create();
    if (!instance->mpv) {
        if (instance->appCtx)
            env->DeleteGlobalRef(instance->appCtx);
        if (instance->javaObject)
            env->DeleteGlobalRef(instance->javaObject);
        delete instance;
        return 0;
    }

    mpv_request_log_messages(instance->mpv, "v");
    return reinterpret_cast<jlong>(instance);
}

jni_func(void, nativeInit, jlong instance) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->mpv) {
        die(env, "mpv is not created");
        return;
    }

    if (mpv_initialize(mpv_instance->mpv) < 0) {
        die(env, "mpv init failed");
        return;
    }

    mpv_instance->event_thread_request_exit = false;
    mpv_instance->teardown_request_complete = false;
    mpv_instance->event_thread_start_state = EVENT_THREAD_STARTING;
    pthread_t created_event_thread;
    if (pthread_create(&created_event_thread, nullptr, event_thread, mpv_instance) != 0) {
        mpv_instance->event_thread_id = 0;
        die(env, "thread create failed");
        return;
    }
    mpv_instance->event_thread_id = created_event_thread;

    int start_state;
    while ((start_state = mpv_instance->event_thread_start_state.load(std::memory_order_acquire)) ==
        EVENT_THREAD_STARTING) {
        std::this_thread::yield();
    }
    if (start_state == EVENT_THREAD_JNI_ATTACH_FAILED) {
        pthread_join(mpv_instance->event_thread_id, nullptr);
        mpv_instance->event_thread_id = 0;
        die(env, "event thread failed to attach to Java VM");
        return;
    }
    pthread_setname_np(mpv_instance->event_thread_id, "event_thread");
}

jni_func(void, nativeDestroy, jlong instance) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->mpv) {
        ALOGV("Cannot destroy mpv: mpv is not initialized");
        return;
    }

    const pthread_t event_thread_id = mpv_instance->event_thread_id;
    if (event_thread_id == 0) {
        finalize_mpv_instance(env, mpv_instance);
        return;
    }

    // The event thread is the final-teardown owner whenever it exists. This makes a destroy requested
    // synchronously by a Java event listener safe: nativeDestroy only requests exit and returns, then the
    // event loop unwinds past CallVoidMethod before freeing mpv, GlobalRefs, and MPVInstance. For an
    // ordinary caller, copy the pthread id before wakeup and never dereference mpv_instance after wakeup;
    // the event thread may legally free it before pthread_join returns.
    mpv_instance->event_thread_request_exit = true;
    mpv_wakeup(mpv_instance->mpv);
    // Publish only after the last caller-side dereference. The awakened event thread is allowed to
    // finalize and delete MPVInstance as soon as this release-store becomes visible.
    mpv_instance->teardown_request_complete.store(true, std::memory_order_release);

    if (pthread_equal(pthread_self(), event_thread_id)) {
        const int detach_result = pthread_detach(event_thread_id);
        if (detach_result != 0)
            ALOGE("event thread self-detach failed (%d)", detach_result);
        return;
    }

    const int join_result = pthread_join(event_thread_id, nullptr);
    if (join_result != 0) {
        // Cleanup is still owned by the awakened event thread. A join failure must not fall through and
        // free state that the event loop can still touch.
        ALOGE("event thread join failed (%d); deferred teardown remains event-thread owned", join_result);
        pthread_detach(event_thread_id);
    }
}

jni_func(void, nativeCommand, jlong instance, jobjectArray jarray) {
    auto mpv_instance = reinterpret_cast<MPVInstance*>(instance);
    if (!mpv_instance->mpv) {
        ALOGE("Cannot run command: mpv is not initialized");
        return;
    }

    const char *arguments[128] = { nullptr };
    jstring stringRefs[128] = { nullptr };

    int len = env->GetArrayLength(jarray);

    if (len >= ARRAYLEN(arguments)) {
        ALOGE("Cannot run command: too many arguments");
        return;
    }

    for (int i = 0; i < len; ++i) {
        stringRefs[i] = (jstring)env->GetObjectArrayElement(jarray, i);
        arguments[i] = env->GetStringUTFChars(stringRefs[i], nullptr);
    }

    mpv_command(mpv_instance->mpv, arguments);

    for (int i = 0; i < len; ++i) {
        if (stringRefs[i]) {
            env->ReleaseStringUTFChars(stringRefs[i], arguments[i]);
            env->DeleteLocalRef(stringRefs[i]);
        }
    }
}
