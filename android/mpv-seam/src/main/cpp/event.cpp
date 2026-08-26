// Forked from jarnedemeulemeester/libmpv-android v1.0.0 (MIT), file libmpv/src/main/cpp/event.cpp.
//
// THE ONE BEHAVIORAL PATCH OF THIS FORK (VortX audit W1-B / AND-PLY-01): upstream's event loop
// dispatches MPV_EVENT_END_FILE through the generic default branch, which forwards ONLY the event id
// and drops mpv_event->data -- so the Kotlin side can never learn WHY a file ended. This fork adds an
// explicit MPV_EVENT_END_FILE case that reads struct mpv_event_end_file and calls
// MpvSeam.eventEndFile(int reason, int error):
//   - reason is mpv_event_end_file.reason verbatim (client.h MPV_END_FILE_REASON_*: EOF=0, STOP=2,
//     QUIT=3, ERROR=4, REDIRECT=5; unknown future codes pass through untouched for fail-safe handling).
//   - error is .error when reason==MPV_END_FILE_REASON_ERROR, else 0. client.h documents .error as
//     present only for the ERROR reason, so other reasons deliberately carry 0 rather than a stale or
//     meaningless value.
// Event ORDERING IS PRESERVED: END_FILE still leaves mpv's per-client queue in FIFO order relative to
// START_FILE and every other event, which is what lets the Kotlin terminal reducer bind its
// replacement-suppression window to START_FILE.
#include <jni.h>

#include <mpv/client.h>

#include "globals.h"
#include "jni_utils.h"
#include "log.h"


static void sendPropertyUpdateToJava(JNIEnv *env, MPVInstance* instance, mpv_event_property *prop) {
    jstring jprop = env->NewStringUTF(prop->name);
    jstring jvalue = nullptr;
    switch (prop->format) {
    case MPV_FORMAT_NONE:
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventProperty_S, jprop);
        break;
    case MPV_FORMAT_FLAG:
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventProperty_Sb, jprop, *(int*)prop->data);
        break;
    case MPV_FORMAT_INT64:
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventProperty_Sl, jprop, *(int64_t*)prop->data);
        break;
    case MPV_FORMAT_DOUBLE:
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventProperty_Sd, jprop, *(double*)prop->data);
        break;
    case MPV_FORMAT_STRING:
        jvalue = env->NewStringUTF(*(const char**)prop->data);
        env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventProperty_SS, jprop, jvalue);
        break;
    default:
        ALOGV("sendPropertyUpdateToJava: Unknown property update format received in callback: %d!", prop->format);
        break;
    }
    if (jprop)
        env->DeleteLocalRef(jprop);
    if (jvalue)
        env->DeleteLocalRef(jvalue);
}

static void sendEventToJava(JNIEnv *env, MPVInstance* instance, int event) {
    env->CallVoidMethod(instance->javaObject, seam_MpvSeam_event, event);
}

static void sendEndFileToJava(JNIEnv *env, MPVInstance* instance, int reason, int error) {
    env->CallVoidMethod(instance->javaObject, seam_MpvSeam_eventEndFile_II, reason, error);
}

static void sendLogMessageToJava(JNIEnv *env, MPVInstance* instance, mpv_event_log_message *msg) {
    // filter the most obvious cases of invalid utf-8, since Java would choke on it
    const auto invalid_utf8 = [] (unsigned char c) {
        return c == 0xc0 || c == 0xc1 || c >= 0xf5;
    };
    for (int i = 0; msg->text[i]; i++) {
        if (invalid_utf8(static_cast<unsigned char>(msg->text[i])))
            return;
    }

    jstring jprefix = env->NewStringUTF(msg->prefix);
    jstring jtext = env->NewStringUTF(msg->text);

    env->CallVoidMethod(instance->javaObject, seam_MpvSeam_logMessage_SiS,
        jprefix, (jint) msg->log_level, jtext);

    if (jprefix)
        env->DeleteLocalRef(jprefix);
    if (jtext)
        env->DeleteLocalRef(jtext);
}

void *event_thread(void *arg) {
    auto instance = static_cast<MPVInstance*>(arg);
    JNIEnv *env = nullptr;
    acquire_jni_env(instance->vm, &env);
    if (!env) {
        ALOGE("failed to acquire java env");
        return nullptr;
    }

    while (true) {
        mpv_event *mp_event;
        mpv_event_property *mp_property;
        mpv_event_log_message *msg;

        mp_event = mpv_wait_event(instance->mpv, -1.0);

        if (instance->event_thread_request_exit)
            break;

        if (mp_event->event_id == MPV_EVENT_NONE)
            continue;

        switch (mp_event->event_id) {
        case MPV_EVENT_LOG_MESSAGE:
            msg = (mpv_event_log_message*)mp_event->data;
            ALOGV("[%s:%s] %s", msg->prefix, msg->level, msg->text);
            sendLogMessageToJava(env, instance, msg);
            break;
        case MPV_EVENT_PROPERTY_CHANGE:
            mp_property = (mpv_event_property*)mp_event->data;
            sendPropertyUpdateToJava(env, instance, mp_property);
            break;
        case MPV_EVENT_END_FILE: {
            // The W1-B payload seam. See the file comment: forward the real end-file reason, plus the
            // native error code for ERROR terminations only.
            mpv_event_end_file *end_file = (mpv_event_end_file*)mp_event->data;
            sendEndFileToJava(env, instance, (int)end_file->reason,
                end_file->reason == MPV_END_FILE_REASON_ERROR ? (int)end_file->error : 0);
            break;
        }
        default:
            ALOGV("event: %s\n", mpv_event_name(mp_event->event_id));
            sendEventToJava(env, instance, mp_event->event_id);
            break;
        }
    }

    instance->vm->DetachCurrentThread();

    return nullptr;
}
