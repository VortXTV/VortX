// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/globals.h,
// then renamed to the VortX seam class (see README.md in this directory for provenance and the
// complete event/lifecycle delta inventory). Upstream MIT license text ships as LICENSE one level up.
#pragma once

#include <atomic>
#include <pthread.h>
#include <jni.h>
#include <mpv/client.h>

enum EventThreadStartState {
    EVENT_THREAD_STARTING = 0,
    EVENT_THREAD_READY = 1,
    EVENT_THREAD_JNI_ATTACH_FAILED = -1,
};

// struct to hold the mpv_handle and other related data
struct MPVInstance {
    mpv_handle *mpv;
    JavaVM *vm;
    pthread_t event_thread_id;
    std::atomic<bool> event_thread_request_exit;
    std::atomic<bool> teardown_request_complete;
    std::atomic<int> event_thread_start_state;

    jobject javaObject;
    jobject appCtx;
    jobject surface;
};

// Release the mpv handle, every owned GlobalRef, and the instance itself on a thread with a valid
// JNIEnv. When an event thread exists, that thread calls this only after its Java callback unwinds.
void finalize_mpv_instance(JNIEnv *env, MPVInstance *instance);
