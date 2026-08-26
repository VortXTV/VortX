// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/log.h.
// Only the log tag differs so VortxMpvSeam lines are distinguishable from the artifact's own
// libplayer.so logs in logcat.
#pragma once

#include <android/log.h>
#include <jni.h>

#define DEBUG 1

#define LOG_TAG "VortxMpvSeam"
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#if DEBUG
#define ALOGV(...) __android_log_print(ANDROID_LOG_VERBOSE, LOG_TAG, __VA_ARGS__)
#else
#define ALOGV(...) (void)0
#endif

void die(JNIEnv *env, const char *msg);
void throw_java_exception(JNIEnv *env, const char *msg);
