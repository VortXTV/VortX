#include "VortXQuickJSBridge.h"
#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Implemented by Swift. It applies URL, method, header, body, concurrency, and byte budgets before returning
 * a JSON response object. The bridge exposes no application credential or provider-controlled diagnostics. */
extern char *VortXQuickJSFetch(void *host, const char *url, const char *options_json);

enum { VORTX_QJS_OK = 0, VORTX_QJS_INTERRUPTED = 1, VORTX_QJS_LIMIT = 2, VORTX_QJS_FAILED = 3 };

typedef struct {
    void *host;
    volatile int32_t *cancelled;
    int64_t deadline_millis;
    char *result;
    int complete;
    int interrupted;
    int timer_count;
} VortXQuickJSState;

static int64_t now_millis(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int should_interrupt(JSRuntime *runtime, void *opaque) {
    VortXQuickJSState *state = opaque;
    int stop = *(state->cancelled) != 0 || now_millis() >= state->deadline_millis;
    if (stop) state->interrupted = 1;
    return stop;
}

static JSValue fixed_error(JSContext *ctx, JSValueConst reject, const char *message) {
    JSValue argument = JS_NewString(ctx, message);
    JSValue ignored = JS_Call(ctx, reject, JS_UNDEFINED, 1, (JSValueConst *)&argument);
    JS_FreeValue(ctx, ignored);
    JS_FreeValue(ctx, argument);
    return JS_UNDEFINED;
}

static JSValue native_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    VortXQuickJSState *state = JS_GetContextOpaque(ctx);
    if (argc != 4 || !state || should_interrupt(JS_GetRuntime(ctx), state)) {
        return argc >= 4 ? fixed_error(ctx, argv[3], "request rejected") : JS_EXCEPTION;
    }
    const char *url = JS_ToCString(ctx, argv[0]);
    const char *options = JS_ToCString(ctx, argv[1]);
    if (!url || !options || strlen(url) > 16384 || strlen(options) > 32768) {
        if (url) JS_FreeCString(ctx, url);
        if (options) JS_FreeCString(ctx, options);
        return fixed_error(ctx, argv[3], "request rejected");
    }
    char *response = VortXQuickJSFetch(state->host, url, options);
    JS_FreeCString(ctx, url);
    JS_FreeCString(ctx, options);
    if (!response) return fixed_error(ctx, argv[3], "request rejected");
    JSValue payload = JS_ParseJSON(ctx, response, strlen(response), "native-response");
    free(response);
    if (JS_IsException(payload)) return fixed_error(ctx, argv[3], "response rejected");
    JSValue ignored = JS_Call(ctx, argv[2], JS_UNDEFINED, 1, (JSValueConst *)&payload);
    JS_FreeValue(ctx, ignored);
    JS_FreeValue(ctx, payload);
    return JS_UNDEFINED;
}

static JSValue native_complete(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    VortXQuickJSState *state = JS_GetContextOpaque(ctx);
    if (!state || argc != 1 || state->complete) return JS_UNDEFINED;
    const char *json = JS_ToCString(ctx, argv[0]);
    if (json && strlen(json) <= 1024 * 1024) {
        state->result = strdup(json);
        state->complete = state->result != NULL;
    }
    if (json) JS_FreeCString(ctx, json);
    return JS_UNDEFINED;
}

static JSValue native_fail(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_UNDEFINED; /* Provider-controlled text is never persisted or logged. */
}

static JSValue native_log(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    return JS_UNDEFINED; /* Fixed host diagnostics only. */
}

static JSValue native_timer(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    VortXQuickJSState *state = JS_GetContextOpaque(ctx);
    if (!state || state->timer_count++ >= 16) return JS_NewInt32(ctx, 0);
    if (argc >= 1 && JS_IsFunction(ctx, argv[0])) {
        JSValue ignored = JS_Call(ctx, argv[0], JS_UNDEFINED, 0, NULL);
        JS_FreeValue(ctx, ignored);
    }
    return JS_NewInt32(ctx, 0);
}

static int evaluate(JSContext *ctx, const char *source, const char *name) {
    JSValue value = JS_Eval(ctx, source, strlen(source), name, JS_EVAL_TYPE_GLOBAL);
    int failed = JS_IsException(value);
    JS_FreeValue(ctx, value);
    return failed ? -1 : 0;
}

static int capture_library(JSContext *ctx, const char *source, const char *global) {
    const char *prefix = "globalThis.";
    const char *start = "=(function(){var m={exports:{}};(function(module,exports){\n";
    const char *end = "\n})(m,m.exports);return m.exports;})();";
    size_t size = strlen(prefix) + strlen(global) + strlen(start) + strlen(source) + strlen(end) + 1;
    char *wrapped = malloc(size);
    if (!wrapped) return -1;
    snprintf(wrapped, size, "%s%s%s%s%s", prefix, global, start, source, end);
    int status = evaluate(ctx, wrapped, global);
    free(wrapped);
    return status;
}

char *VortXQuickJSRun(const char *crypto_source, const char *cheerio_source, const char *preamble_source,
                      const char *provider_source, const char *params_json, const char *settings_json,
                      const char *provider_id, void *host, volatile int32_t *cancelled,
                      int64_t deadline_millis, int *result_code) {
    *result_code = VORTX_QJS_FAILED;
    VortXQuickJSState state = { .host = host, .cancelled = cancelled, .deadline_millis = deadline_millis };
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) return NULL;
    JS_SetMemoryLimit(runtime, 24 * 1024 * 1024);
    JS_SetMaxStackSize(runtime, 512 * 1024);
    JS_SetInterruptHandler(runtime, should_interrupt, &state);
    JSContext *ctx = JS_NewContext(runtime);
    if (!ctx) { JS_FreeRuntime(runtime); return NULL; }
    JS_SetContextOpaque(ctx, &state);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "__vortx_native_fetch", JS_NewCFunction(ctx, native_fetch, "fetch", 4));
    JS_SetPropertyStr(ctx, global, "__vortx_native_complete", JS_NewCFunction(ctx, native_complete, "complete", 1));
    JS_SetPropertyStr(ctx, global, "__vortx_native_fail", JS_NewCFunction(ctx, native_fail, "fail", 1));
    JS_SetPropertyStr(ctx, global, "__vortx_native_log", JS_NewCFunction(ctx, native_log, "log", 2));
    JS_SetPropertyStr(ctx, global, "__vortx_native_set_timeout", JS_NewCFunction(ctx, native_timer, "timer", 2));
    JS_SetPropertyStr(ctx, global, "__vortx_native_clear_timeout", JS_NewCFunction(ctx, native_log, "clearTimer", 1));
    JS_SetPropertyStr(ctx, global, "URL_VALIDATION_ENABLED", JS_NewBool(ctx, 1));
    JS_FreeValue(ctx, global);
    int failed = capture_library(ctx, crypto_source, "__vortx_cryptojs") ||
                 capture_library(ctx, cheerio_source, "__vortx_cheerio") ||
                 evaluate(ctx, preamble_source, "runtime-preamble");
    if (!failed) {
        JSValue global_run = JS_GetGlobalObject(ctx);
        JSValue runner = JS_GetPropertyStr(ctx, global_run, "__vortx_run");
        JSValue args[4] = { JS_NewString(ctx, provider_source), JS_NewString(ctx, params_json),
                            JS_NewString(ctx, settings_json), JS_NewString(ctx, provider_id) };
        JSValue ignored = JS_Call(ctx, runner, JS_UNDEFINED, 4, args);
        if (JS_IsException(ignored)) failed = 1;
        for (int i = 0; i < 4; i++) JS_FreeValue(ctx, args[i]);
        JS_FreeValue(ctx, ignored);
        JS_FreeValue(ctx, runner);
        JS_FreeValue(ctx, global_run);
        while (!state.complete && !should_interrupt(runtime, &state)) {
            JSContext *job_ctx = NULL;
            int job = JS_ExecutePendingJob(runtime, &job_ctx);
            if (job <= 0) break;
        }
    }
    if (state.complete) { *result_code = VORTX_QJS_OK; }
    else if (state.interrupted || should_interrupt(runtime, &state)) { *result_code = VORTX_QJS_INTERRUPTED; }
    else if (failed) { *result_code = VORTX_QJS_LIMIT; }
    else { *result_code = VORTX_QJS_FAILED; }
    JS_FreeContext(ctx);
    JS_FreeRuntime(runtime);
    return state.result;
}

void VortXQuickJSFree(void *value) { free(value); }
