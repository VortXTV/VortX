// Forked verbatim from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file
// libmpv/src/main/cpp/log.cpp.
#include "log.h"

#include "globals.h"
#include "jni_utils.h"

void die(JNIEnv *env, const char *msg)
{
    ALOGE("%s", msg);
    throw_java_exception(env, msg);
}

void throw_java_exception(JNIEnv *env, const char *msg)
{
    jclass runtimeClass = env->FindClass("java/lang/RuntimeException");
    if (runtimeClass == nullptr) {
        return;
    }

    env->ThrowNew(runtimeClass, msg);

    env->DeleteLocalRef(runtimeClass);
}
