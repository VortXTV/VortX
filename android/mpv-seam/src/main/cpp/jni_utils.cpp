// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file
// libmpv/src/main/cpp/jni_utils.cpp. Changes vs upstream: the cached class/method ids point at
// com.vortx.android.player.mpv.seam.MpvSeam instead of dev.jdtech.mpv.MPVLib, and ONE new method id
// (eventEndFile "(II)V") is cached for the end-file reason/error seam this fork exists to provide.
#define UTIL_EXTERN
#include "jni_utils.h"

#include <jni.h>
#include <cstdlib>
#include <mutex>

bool acquire_jni_env(JavaVM *vm, JNIEnv **env)
{
    int ret = vm->GetEnv((void**)env, JNI_VERSION_1_6);

    if (ret == JNI_EDETACHED) {
        return vm->AttachCurrentThread(env, nullptr) == JNI_OK;
    }

    return ret == JNI_OK;
}

static std::once_flag init_flag;

// Apparently it's considered slow to FindClass and GetMethodID every time we need them,
// so let's have a nice cache here
void init_methods_cache(JNIEnv *env) {
    std::call_once(init_flag, [env]() {
        auto find_and_ref = [&](const char* name) -> jclass {
            jclass localClass = env->FindClass(name);
            auto globalRef = reinterpret_cast<jclass>(env->NewGlobalRef(localClass));
            env->DeleteLocalRef(localClass);
            return globalRef;
        };

        java_Integer = find_and_ref("java/lang/Integer");
        java_Integer_init = env->GetMethodID(java_Integer, "<init>", "(I)V");
        java_Double = find_and_ref("java/lang/Double");
        java_Double_init = env->GetMethodID(java_Double, "<init>", "(D)V");
        java_Boolean = find_and_ref("java/lang/Boolean");
        java_Boolean_init = env->GetMethodID(java_Boolean, "<init>", "(Z)V");

        seam_MpvSeam = find_and_ref("com/vortx/android/player/mpv/seam/MpvSeam");
        seam_MpvSeam_eventProperty_S  = env->GetMethodID(seam_MpvSeam, "eventProperty", "(Ljava/lang/String;)V"); // eventProperty(String)
        seam_MpvSeam_eventProperty_Sb = env->GetMethodID(seam_MpvSeam, "eventProperty", "(Ljava/lang/String;Z)V"); // eventProperty(String, boolean)
        seam_MpvSeam_eventProperty_Sl = env->GetMethodID(seam_MpvSeam, "eventProperty", "(Ljava/lang/String;J)V"); // eventProperty(String, long)
        seam_MpvSeam_eventProperty_Sd = env->GetMethodID(seam_MpvSeam, "eventProperty", "(Ljava/lang/String;D)V"); // eventProperty(String, double)
        seam_MpvSeam_eventProperty_SS = env->GetMethodID(seam_MpvSeam, "eventProperty", "(Ljava/lang/String;Ljava/lang/String;)V"); // eventProperty(String, String)
        // THE W1-B SEAM: eventEndFile(int reason, int error). reason is mpv_event_end_file.reason
        // verbatim (MPV_END_FILE_REASON_*); error is .error when reason==MPV_END_FILE_REASON_ERROR,
        // else 0 (client.h documents .error as present only for the ERROR reason).
        seam_MpvSeam_eventEndFile_II = env->GetMethodID(seam_MpvSeam, "eventEndFile", "(II)V"); // eventEndFile(int, int)
        seam_MpvSeam_event = env->GetMethodID(seam_MpvSeam, "event", "(I)V"); // event(int)
        seam_MpvSeam_logMessage_SiS = env->GetMethodID(seam_MpvSeam, "logMessage", "(Ljava/lang/String;ILjava/lang/String;)V"); // logMessage(String, int, String)
    });
}
