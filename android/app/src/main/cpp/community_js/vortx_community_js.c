#include <jni.h>
#include <android/log.h>
#include <quickjs.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG "community-js"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)
#define MAX_RESULT_BYTES (1024 * 1024)
#define MAX_ERROR_BYTES 1024

typedef struct {
  JavaVM *vm;
  jobject host;
  jmethodID fetch;
  jmethodID is_cancelled;
  int64_t deadline_ms;
  char *result;
  char *error;
} RunState;

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((int64_t) ts.tv_sec * 1000) + ts.tv_nsec / 1000000;
}

static void set_text(char **target, const char *text) {
  free(*target);
  *target = text ? strdup(text) : NULL;
}

static jstring envelope(JNIEnv *env, int ok, const char *text) {
  if (ok) {
    size_t length = strlen(text) + 32;
    char *json = malloc(length);
    if (json == NULL) return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"Out of memory\"}");
    snprintf(json, length, "{\"ok\":true,\"payload\":%s}", text);
    jstring result = (*env)->NewStringUTF(env, json);
    free(json);
    return result;
  }
  /* Do not interpolate an untrusted exception into JSON. The execution error remains native-only. */
  return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"Provider execution failed\"}");
}

static int interrupt_handler(JSRuntime *runtime, void *opaque) {
  (void) runtime;
  RunState *state = opaque;
  if (state == NULL || now_ms() > state->deadline_ms) return 1;
  JNIEnv *env = NULL;
  if ((*state->vm)->GetEnv(state->vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) return 1;
  jboolean cancelled = (*env)->CallBooleanMethod(env, state->host, state->is_cancelled);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    return 1;
  }
  return cancelled == JNI_TRUE;
}

static JSValue host_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void) this_val;
  RunState *state = JS_GetContextOpaque(ctx);
  if (state == NULL || argc < 2) return JS_ThrowTypeError(ctx, "fetch requires URL and options");
  JNIEnv *env = NULL;
  if ((*state->vm)->GetEnv(state->vm, (void **) &env, JNI_VERSION_1_6) != JNI_OK) {
    return JS_ThrowInternalError(ctx, "native thread unavailable");
  }
  const char *url = JS_ToCString(ctx, argv[0]);
  const char *options = JS_ToCString(ctx, argv[1]);
  if (url == NULL || options == NULL) {
    if (url) JS_FreeCString(ctx, url);
    if (options) JS_FreeCString(ctx, options);
    return JS_EXCEPTION;
  }
  jstring jurl = (*env)->NewStringUTF(env, url);
  jstring joptions = (*env)->NewStringUTF(env, options);
  jlong remaining_ms = (jlong) (state->deadline_ms - now_ms());
  if (remaining_ms <= 0) {
    JS_FreeCString(ctx, url);
    JS_FreeCString(ctx, options);
    (*env)->DeleteLocalRef(env, jurl);
    (*env)->DeleteLocalRef(env, joptions);
    return JS_ThrowInternalError(ctx, "execution timed out");
  }
  jstring response = (jstring) (*env)->CallObjectMethod(env, state->host, state->fetch, jurl, joptions, remaining_ms);
  JS_FreeCString(ctx, url);
  JS_FreeCString(ctx, options);
  (*env)->DeleteLocalRef(env, jurl);
  (*env)->DeleteLocalRef(env, joptions);
  if ((*env)->ExceptionCheck(env)) {
    (*env)->ExceptionClear(env);
    return JS_ThrowInternalError(ctx, "native fetch failed");
  }
  if (response == NULL) return JS_ThrowInternalError(ctx, "native fetch returned no response");
  const char *json = (*env)->GetStringUTFChars(env, response, NULL);
  JSValue value = JS_ParseJSON(ctx, json, strlen(json), "native-fetch.json");
  (*env)->ReleaseStringUTFChars(env, response, json);
  (*env)->DeleteLocalRef(env, response);
  return value;
}

static JSValue complete_success(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void) this_val;
  RunState *state = JS_GetContextOpaque(ctx);
  if (state == NULL || argc < 1) return JS_UNDEFINED;
  const char *text = JS_ToCString(ctx, argv[0]);
  if (text != NULL) {
    if (strlen(text) <= MAX_RESULT_BYTES) set_text(&state->result, text);
    else set_text(&state->error, "Provider result exceeds the limit");
    JS_FreeCString(ctx, text);
  }
  return JS_UNDEFINED;
}

static JSValue complete_failure(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
  (void) this_val;
  RunState *state = JS_GetContextOpaque(ctx);
  if (state == NULL || argc < 1) return JS_UNDEFINED;
  const char *text = JS_ToCString(ctx, argv[0]);
  if (text != NULL) {
    size_t text_length = strlen(text);
    size_t copy_length = text_length > MAX_ERROR_BYTES ? MAX_ERROR_BYTES : text_length;
    char *copy = malloc(copy_length + 1);
    if (copy != NULL) {
      memcpy(copy, text, copy_length);
      copy[copy_length] = '\0';
      set_text(&state->error, copy);
      free(copy);
    }
    JS_FreeCString(ctx, text);
  }
  return JS_UNDEFINED;
}

static char *exception_text(JSContext *ctx) {
  JSValue exception = JS_GetException(ctx);
  const char *text = JS_ToCString(ctx, exception);
  char *copy = text ? strdup(text) : strdup("JavaScript execution failed");
  if (text) JS_FreeCString(ctx, text);
  JS_FreeValue(ctx, exception);
  return copy;
}

JNIEXPORT jstring JNICALL
Java_com_vortx_android_communityjs_CommunityJsNative_evaluate(
    JNIEnv *env, jclass clazz, jobject host, jstring code, jstring tmdb_id, jstring media_type,
    jint season, jint episode, jlong timeout_ms, jlong memory_limit) {
  (void) clazz;
  const char *source = (*env)->GetStringUTFChars(env, code, NULL);
  const char *tmdb = (*env)->GetStringUTFChars(env, tmdb_id, NULL);
  const char *media = (*env)->GetStringUTFChars(env, media_type, NULL);
  if (source == NULL || tmdb == NULL || media == NULL) return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"Invalid input\"}");
  RunState state = {0};
  (*env)->GetJavaVM(env, &state.vm);
  state.host = (*env)->NewGlobalRef(env, host);
  jclass host_class = (*env)->GetObjectClass(env, host);
  state.fetch = (*env)->GetMethodID(env, host_class, "fetch", "(Ljava/lang/String;Ljava/lang/String;J)Ljava/lang/String;");
  state.is_cancelled = (*env)->GetMethodID(env, host_class, "isCancelled", "()Z");
  (*env)->DeleteLocalRef(env, host_class);
  state.deadline_ms = now_ms() + timeout_ms;
  JSRuntime *runtime = JS_NewRuntime();
  JSContext *context = runtime ? JS_NewContext(runtime) : NULL;
  if (runtime == NULL || context == NULL || state.fetch == NULL || state.is_cancelled == NULL) {
    if (context) JS_FreeContext(context); if (runtime) JS_FreeRuntime(runtime);
    (*env)->DeleteGlobalRef(env, state.host);
    (*env)->ReleaseStringUTFChars(env, code, source); (*env)->ReleaseStringUTFChars(env, tmdb_id, tmdb); (*env)->ReleaseStringUTFChars(env, media_type, media);
    return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"Runtime unavailable\"}");
  }
  JS_SetMemoryLimit(runtime, (size_t) memory_limit);
  JS_SetMaxStackSize(runtime, 256 * 1024);
  JS_SetInterruptHandler(runtime, interrupt_handler, &state);
  JS_SetContextOpaque(context, &state);
  JSValue global = JS_GetGlobalObject(context);
  JS_SetPropertyStr(context, global, "__vortx_native_fetch", JS_NewCFunction(context, host_fetch, "__vortx_native_fetch", 2));
  JS_SetPropertyStr(context, global, "__vortx_complete", JS_NewCFunction(context, complete_success, "__vortx_complete", 1));
  JS_SetPropertyStr(context, global, "__vortx_fail", JS_NewCFunction(context, complete_failure, "__vortx_fail", 1));
  JS_FreeValue(context, global);
  size_t wrapper_size = strlen(source) + strlen(tmdb) + strlen(media) + 2500;
  char *wrapper = malloc(wrapper_size);
  snprintf(wrapper, wrapper_size,
    "(function(){'use strict';const fetch=(u,o)=>Promise.resolve(__vortx_native_fetch(String(u),JSON.stringify(o||{})));const axios={get:(u,o)=>fetch(u,o),request:(o)=>fetch(o.url,o)};const require=(n)=>{if(['crypto-js','cheerio','cheerio-without-node-native','react-native-cheerio'].includes(n))return Object.freeze({});throw new Error('Module '+n+' is not allowed')};const module={exports:{}};const exports=module.exports;const global=globalThis;global.SCRAPER_SETTINGS={};global.SCRAPER_ID='provider';global.TMDB_API_KEY='';const window=global;const URL_VALIDATION_ENABLED=true;%s;const f=typeof getStreams==='function'?getStreams:(module.exports&&module.exports.getStreams)||global.getStreams;if(typeof f!=='function')throw new Error('No getStreams function found');Promise.resolve(f('%s','%s',%d,%d)).then(v=>__vortx_complete(JSON.stringify(Array.isArray(v)?v:[]))).catch(e=>__vortx_fail(String(e)));})()",
    source, tmdb, media, season, episode);
  JSValue eval = JS_Eval(context, wrapper, strlen(wrapper), "community-provider.js", JS_EVAL_TYPE_GLOBAL);
  free(wrapper);
  if (JS_IsException(eval)) set_text(&state.error, exception_text(context));
  JS_FreeValue(context, eval);
  while (state.error == NULL && state.result == NULL && now_ms() <= state.deadline_ms) {
    JSContext *job_context = NULL;
    int pending = JS_ExecutePendingJob(runtime, &job_context);
    if (pending < 0) { set_text(&state.error, exception_text(job_context ? job_context : context)); break; }
    if (pending == 0) break;
  }
  jstring result = envelope(env, state.result != NULL, state.result ? state.result : "");
  free(state.result); free(state.error); JS_FreeContext(context); JS_FreeRuntime(runtime); (*env)->DeleteGlobalRef(env, state.host);
  (*env)->ReleaseStringUTFChars(env, code, source); (*env)->ReleaseStringUTFChars(env, tmdb_id, tmdb); (*env)->ReleaseStringUTFChars(env, media_type, media);
  return result;
}
