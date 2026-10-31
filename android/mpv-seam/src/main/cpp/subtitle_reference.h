#pragma once
#include <jni.h>
#include <mpv/client.h>
#include "globals.h"

// Copies only the bounded scalar/cue map protocol; never retains event-owned mpv_node storage.
jobject copy_reference_node(JNIEnv *env, const mpv_node *node);
void send_reference_reply(JNIEnv *env, MPVInstance *instance, const mpv_event *event);
