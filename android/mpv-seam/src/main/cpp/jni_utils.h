// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file
// libmpv/src/main/cpp/jni_utils.h, renamed to the VortX seam JNI symbol prefix
// (Java_com_vortx_android_player_mpv_seam_MpvSeam_*) and extended with ONE addition:
// the cached method id for MpvSeam.eventEndFile(int reason, int error) -- the W1-B terminal
// seam that carries mpv_event_end_file.reason/error out of the native event loop.
#pragma once

#include <jni.h>

#define jni_func_name(name) Java_com_vortx_android_player_mpv_seam_MpvSeam_##name
#define jni_func(return_type, name, ...) JNIEXPORT return_type JNICALL jni_func_name(name) (JNIEnv *env, jobject obj, ##__VA_ARGS__)

bool acquire_jni_env(JavaVM *vm, JNIEnv **env);
void init_methods_cache(JNIEnv *env);

#ifndef UTIL_EXTERN
#define UTIL_EXTERN extern
#endif

UTIL_EXTERN jclass java_Integer, java_Double, java_Boolean;
UTIL_EXTERN jmethodID java_Integer_init, java_Double_init, java_Boolean_init;

UTIL_EXTERN jclass seam_MpvSeam;
UTIL_EXTERN jmethodID seam_MpvSeam_eventProperty_S,
        seam_MpvSeam_eventProperty_Sb,
        seam_MpvSeam_eventProperty_Sl,
        seam_MpvSeam_eventProperty_Sd,
        seam_MpvSeam_eventProperty_SS,
        seam_MpvSeam_eventEndFile_II,
        seam_MpvSeam_event,
        seam_MpvSeam_logMessage_SiS;
