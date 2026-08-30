// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/globals.h,
// then renamed to the VortX seam class (see README.md in this directory for provenance and the
// complete event/lifecycle delta inventory). Upstream MIT license text ships as LICENSE one level up.
#pragma once

#include <atomic>
#include <pthread.h>
#include <jni.h>
#include <mpv/client.h>

// struct to hold the mpv_handle and other related data
struct MPVInstance {
    mpv_handle *mpv;
    JavaVM *vm;
    pthread_t event_thread_id;
    std::atomic<bool> event_thread_request_exit;

    jobject javaObject;
    jobject appCtx;
    jobject surface;
};
