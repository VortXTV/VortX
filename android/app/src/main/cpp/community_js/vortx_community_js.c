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
/* Binder returns a UTF-16 String in a shared ~1 MiB transaction buffer. Keep UTF-8 output
 * conservatively below 192 KiB so envelope, UTF-16 expansion, and parcel metadata fit safely. */
#define MAX_RESULT_BYTES (192 * 1024)
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

static jstring java_from_utf8(JNIEnv *env, const char *bytes, size_t length);

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((int64_t) ts.tv_sec * 1000) + ts.tv_nsec / 1000000;
}

static int set_text(char **target, const char *text) {
  free(*target);
  *target = NULL;
  if (text == NULL) return 1;
  size_t length = strlen(text);
  char *copy = malloc(length + 1);
  if (copy == NULL) return 0;
  memcpy(copy, text, length + 1);
  *target = copy;
  return 1;
}

/* JNI's GetStringUTFChars is modified UTF-8. Providers are ordinary UTF-8, including emoji/NUL, so
 * convert UTF-16 explicitly at the boundary instead of silently altering script or result bytes. */
static char *utf8_from_java(JNIEnv *env, jstring value, size_t *out_length) {
  if (value == NULL) return NULL;
  jsize count = (*env)->GetStringLength(env, value);
  const jchar *chars = (*env)->GetStringChars(env, value, NULL);
  if (chars == NULL || count < 0 || (size_t)count > (SIZE_MAX - 1) / 3) return NULL;
  char *out = malloc((size_t)count * 3 + 1);
  if (out == NULL) { (*env)->ReleaseStringChars(env, value, chars); return NULL; }
  size_t write = 0;
  for (jsize i = 0; i < count; i++) {
    uint32_t code = chars[i];
    if (code >= 0xD800 && code <= 0xDBFF && i + 1 < count && chars[i + 1] >= 0xDC00 && chars[i + 1] <= 0xDFFF) {
      code = 0x10000 + ((code - 0xD800) << 10) + (chars[++i] - 0xDC00);
    } else if (code >= 0xD800 && code <= 0xDFFF) code = 0xFFFD;
    if (code < 0x80) out[write++] = (char)code;
    else if (code < 0x800) { out[write++] = 0xC0 | (code >> 6); out[write++] = 0x80 | (code & 0x3F); }
    else if (code < 0x10000) { out[write++] = 0xE0 | (code >> 12); out[write++] = 0x80 | ((code >> 6) & 0x3F); out[write++] = 0x80 | (code & 0x3F); }
    else { out[write++] = 0xF0 | (code >> 18); out[write++] = 0x80 | ((code >> 12) & 0x3F); out[write++] = 0x80 | ((code >> 6) & 0x3F); out[write++] = 0x80 | (code & 0x3F); }
  }
  out[write] = '\0';
  (*env)->ReleaseStringChars(env, value, chars);
  *out_length = write;
  return out;
}

static jstring java_from_utf8(JNIEnv *env, const char *bytes, size_t length) {
  if (length > (SIZE_MAX / sizeof(jchar)) - 1) return NULL;
  jchar *out = malloc((length + 1) * sizeof(jchar));
  if (out == NULL) return NULL;
  size_t read = 0, write = 0;
  while (read < length) {
    uint32_t code = (unsigned char)bytes[read++];
    if (code >= 0xC2 && code <= 0xDF && read < length) code = ((code & 0x1F) << 6) | ((unsigned char)bytes[read++] & 0x3F);
    else if (code >= 0xE0 && code <= 0xEF && read + 1 < length) { uint32_t b = (unsigned char)bytes[read++], c = (unsigned char)bytes[read++]; code = ((code & 0x0F) << 12) | ((b & 0x3F) << 6) | (c & 0x3F); }
    else if (code >= 0xF0 && code <= 0xF4 && read + 2 < length) { uint32_t b = (unsigned char)bytes[read++], c = (unsigned char)bytes[read++], d = (unsigned char)bytes[read++]; code = ((code & 0x07) << 18) | ((b & 0x3F) << 12) | ((c & 0x3F) << 6) | (d & 0x3F); }
    else if (code >= 0x80) code = 0xFFFD;
    if (code > 0x10FFFF) code = 0xFFFD;
    if (code >= 0x10000) { code -= 0x10000; out[write++] = 0xD800 | (code >> 10); out[write++] = 0xDC00 | (code & 0x3FF); }
    else out[write++] = (jchar)code;
  }
  jstring result = (*env)->NewString(env, out, (jsize)write);
  free(out);
  return result;
}

static jstring envelope(JNIEnv *env, int ok, const char *text) {
  if (ok) {
    size_t length = strlen(text) + 32;
    char *json = malloc(length);
    if (json == NULL) { const char *failure = "{\"ok\":false,\"error\":\"Out of memory\"}"; return java_from_utf8(env, failure, strlen(failure)); }
    snprintf(json, length, "{\"ok\":true,\"payload\":%s}", text);
    jstring result = java_from_utf8(env, json, strlen(json));
    free(json);
    return result;
  }
  /* Do not interpolate an untrusted exception into JSON. The execution error remains native-only. */
  { const char *failure = "{\"ok\":false,\"error\":\"Provider execution failed\"}"; return java_from_utf8(env, failure, strlen(failure)); }
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
  size_t url_length = strlen(url), options_length = strlen(options);
  jstring jurl = java_from_utf8(env, url, url_length);
  jstring joptions = java_from_utf8(env, options, options_length);
  if (jurl == NULL || joptions == NULL) {
    if (jurl) (*env)->DeleteLocalRef(env, jurl); if (joptions) (*env)->DeleteLocalRef(env, joptions);
    JS_FreeCString(ctx, url); JS_FreeCString(ctx, options);
    return JS_ThrowInternalError(ctx, "native conversion failed");
  }
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
  size_t json_length = 0;
  char *json = utf8_from_java(env, response, &json_length);
  if (json == NULL) { (*env)->DeleteLocalRef(env, response); return JS_ThrowInternalError(ctx, "native response conversion failed"); }
  JSValue value = JS_ParseJSON(ctx, json, json_length, "native-fetch.json");
  free(json);
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
  const char *fallback = "JavaScript execution failed";
  const char *source = text ? text : fallback;
  size_t length = strlen(source);
  char *copy = malloc(length + 1);
  if (copy != NULL) memcpy(copy, source, length + 1);
  if (text) JS_FreeCString(ctx, text);
  JS_FreeValue(ctx, exception);
  return copy;
}

JNIEXPORT jstring JNICALL
Java_com_vortx_android_communityjs_CommunityJsNative_evaluate(
    JNIEnv *env, jclass clazz, jobject host, jstring code, jstring tmdb_id, jstring media_type,
    jstring settings_json, jint season, jint episode, jlong timeout_ms, jlong memory_limit) {
  (void) clazz;
  size_t source_length = 0, tmdb_length = 0, media_length = 0, settings_length = 0;
  char *source = utf8_from_java(env, code, &source_length);
  char *tmdb = utf8_from_java(env, tmdb_id, &tmdb_length);
  char *media = utf8_from_java(env, media_type, &media_length);
  char *settings = utf8_from_java(env, settings_json, &settings_length);
  if (source == NULL || tmdb == NULL || media == NULL || settings == NULL) { const char *failure = "{\"ok\":false,\"error\":\"Invalid input\"}"; free(source); free(tmdb); free(media); free(settings); return java_from_utf8(env, failure, strlen(failure)); }
  RunState state = {0};
  if ((*env)->GetJavaVM(env, &state.vm) != JNI_OK) {
    free(source); free(tmdb); free(media); free(settings);
    { const char *failure = "{\"ok\":false,\"error\":\"Runtime unavailable\"}"; return java_from_utf8(env, failure, strlen(failure)); }
  }
  state.host = (*env)->NewGlobalRef(env, host);
  jclass host_class = (*env)->GetObjectClass(env, host);
  if (state.host != NULL && host_class != NULL) {
    state.fetch = (*env)->GetMethodID(env, host_class, "fetch", "(Ljava/lang/String;Ljava/lang/String;J)Ljava/lang/String;");
    state.is_cancelled = (*env)->GetMethodID(env, host_class, "isCancelled", "()Z");
  }
  if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
  if (host_class != NULL) (*env)->DeleteLocalRef(env, host_class);
  state.deadline_ms = now_ms() + timeout_ms;
  JSRuntime *runtime = JS_NewRuntime();
  JSContext *context = runtime ? JS_NewContext(runtime) : NULL;
  if (runtime == NULL || context == NULL || state.fetch == NULL || state.is_cancelled == NULL) {
    if (context) JS_FreeContext(context); if (runtime) JS_FreeRuntime(runtime);
    if (state.host != NULL) (*env)->DeleteGlobalRef(env, state.host);
    free(source); free(tmdb); free(media); free(settings);
    { const char *failure = "{\"ok\":false,\"error\":\"Runtime unavailable\"}"; return java_from_utf8(env, failure, strlen(failure)); }
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
  if (source_length > SIZE_MAX - 5000 || tmdb_length > SIZE_MAX - source_length - 5000 ||
      media_length > SIZE_MAX - source_length - tmdb_length - 5000 ||
      settings_length > SIZE_MAX - source_length - tmdb_length - media_length - 5000) {
    JS_FreeContext(context); JS_FreeRuntime(runtime); (*env)->DeleteGlobalRef(env, state.host);
    free(source); free(tmdb); free(media); free(settings);
    { const char *failure = "{\"ok\":false,\"error\":\"Runtime unavailable\"}"; return java_from_utf8(env, failure, strlen(failure)); }
  }
  size_t wrapper_size = source_length + tmdb_length + media_length + settings_length + 5000;
  char *wrapper = malloc(wrapper_size);
  if (wrapper == NULL) {
    JS_FreeContext(context); JS_FreeRuntime(runtime); if (state.host != NULL) (*env)->DeleteGlobalRef(env, state.host);
    free(source); free(tmdb); free(media); free(settings);
    { const char *failure = "{\"ok\":false,\"error\":\"Runtime unavailable\"}"; return java_from_utf8(env, failure, strlen(failure)); }
  }
  snprintf(wrapper, wrapper_size,
    "(function(){'use strict';const __response=(r)=>{const h=r.headers||{},lower={};Object.keys(h).forEach(k=>lower[k.toLowerCase()]=String(h[k]));const headers={get:(k)=>lower[String(k).toLowerCase()]||null,has:(k)=>Object.prototype.hasOwnProperty.call(lower,String(k).toLowerCase()),forEach:(f)=>Object.keys(h).forEach(k=>f(h[k],k))};const text=String(r.body||'');return {ok:r.status>=200&&r.status<300,status:r.status||0,statusText:r.statusText||'',headers,text:()=>Promise.resolve(text),json:()=>{try{return Promise.resolve(JSON.parse(text))}catch(e){return Promise.reject(e)}}}};const fetch=(u,o)=>Promise.resolve(__response(__vortx_native_fetch(String(u),JSON.stringify(o||{}))));const axios={request:(o)=>fetch(o.url,o).then(r=>r.text().then(t=>{let d=t;try{d=JSON.parse(t)}catch(e){}return {data:d,status:r.status,statusText:r.statusText,headers:r.headers,config:o}})),get:(u,o)=>axios.request(Object.assign({},o||{},{url:u,method:'GET'})),post:(u,d,o)=>axios.request(Object.assign({},o||{},{url:u,method:'POST',body:d}))};const require=(n)=>{if(n==='crypto-js')return {MD5:(v)=>({toString:()=>String(v)}),SHA1:(v)=>({toString:()=>String(v)}),SHA256:(v)=>({toString:()=>String(v)})};if(['cheerio','cheerio-without-node-native','react-native-cheerio'].includes(n))return {load:(html)=>{const q=(s)=>({length:0,text:()=>'',attr:()=>null,find:()=>q(''),first:()=>q(''),each:()=>{}});q.html=html;return q}};throw new Error('Module '+n+' is not allowed')};const console={log:()=>{},warn:()=>{},error:()=>{}};const setTimeout=(f)=>{Promise.resolve().then(f);return 0},clearTimeout=()=>{};const TextEncoder=function(){this.encode=(s)=>Uint8Array.from(unescape(encodeURIComponent(String(s))).split('').map(c=>c.charCodeAt(0)))};const TextDecoder=function(){this.decode=(a)=>decodeURIComponent(Array.from(a).map(c=>'%%'+c.toString(16).padStart(2,'0')).join(''))};const URL=function(u,b){this.href=b?String(b).replace(/[^/]*$/,'')+String(u):String(u);this.toString=()=>this.href};const module={exports:{}};const exports=module.exports;const global=globalThis;global.SCRAPER_SETTINGS=%s;global.SCRAPER_ID='provider';global.TMDB_API_KEY='';const window=global;const URL_VALIDATION_ENABLED=true;%s;const f=typeof getStreams==='function'?getStreams:(module.exports&&module.exports.getStreams)||global.getStreams;if(typeof f!=='function')throw new Error('No getStreams function found');Promise.resolve(f('%s','%s',%d,%d)).then(v=>__vortx_complete(JSON.stringify(Array.isArray(v)?v:[]))).catch(e=>__vortx_fail(String(e)));})()",
    settings, source, tmdb, media, season, episode);
  JSValue eval = JS_Eval(context, wrapper, strlen(wrapper), "community-provider.js", JS_EVAL_TYPE_GLOBAL);
  free(wrapper);
  if (JS_IsException(eval)) {
    char *message = exception_text(context);
    if (message == NULL || !set_text(&state.error, message)) set_text(&state.error, "JavaScript execution failed");
    free(message);
  }
  JS_FreeValue(context, eval);
  while (state.error == NULL && state.result == NULL && now_ms() <= state.deadline_ms) {
    JSContext *job_context = NULL;
    int pending = JS_ExecutePendingJob(runtime, &job_context);
    if (pending < 0) {
      char *message = exception_text(job_context ? job_context : context);
      if (message == NULL || !set_text(&state.error, message)) set_text(&state.error, "JavaScript execution failed");
      free(message);
      break;
    }
    if (pending == 0) break;
  }
  jstring result = envelope(env, state.result != NULL, state.result ? state.result : "");
  free(state.result); free(state.error); JS_FreeContext(context); JS_FreeRuntime(runtime); if (state.host != NULL) (*env)->DeleteGlobalRef(env, state.host);
  free(source); free(tmdb); free(media); free(settings);
  return result;
}
