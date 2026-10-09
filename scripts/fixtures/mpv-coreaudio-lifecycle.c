// Test doubles only. Lifecycle functions below are extracted verbatim by the runner.
// Intentionally do NOT link CoreAudio/AudioToolbox: every HAL entry point is fake.
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct coreaudio_cb_sem { int unused; };
/* PRODUCTION_PRIV */
struct mp_log { volatile int alive; };
struct ao;
struct ao_driver { void (*uninit)(struct ao *); };
struct buffer_state {
    bool thread_valid, terminate;
    int pt_lock, pt_wakeup, thread, wakeup, lock;
    void *filter_root, *queue, *pending, *convert_buffer, *temp_buf;
};
struct ao {
    struct priv *priv;
    struct mp_log *log;
    int format, init_flags, samplerate, device_buffer;
    char *device, *redirect;
    bool driver_initialized;
    struct buffer_state *buffer_state;
    struct ao_driver *driver;
};
static void uninit(struct ao *ao);
static bool init_audiounit(struct ao *, AudioStreamBasicDescription, AudioChannelLayout *, size_t);
static bool register_hotplug_cb(struct ao *);
static void unregister_hotplug_cb(struct ao *);
static struct ao *owner;
static const char *scenario;
static int added, removed, live_units, initialized_units, callbacks, restored;
static int latency_calls, disposed;
static bool is_case(const char *value) { return strcmp(scenario, value) == 0; }
static void log_touch(struct ao *ao) { assert(ao->log->alive == 1); }
static void log_message(struct ao *ao, const char *format, ...) { (void)format; log_touch(ao); }
#define MP_VERBOSE(ao, ...) log_message(ao, __VA_ARGS__)
#define MP_ERR(ao, ...) log_message(ao, __VA_ARGS__)
#define MP_ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define AO_INIT_EXCLUSIVE 1
#define CONTROL_ERROR -1
#define CONTROL_OK 0
#define CHECK_CA_ERROR(message) do { if (err != noErr) goto coreaudio_error; } while (0)
#define CHECK_CA_ERROR_L(label, message) do { if (err != noErr) goto label; } while (0)
#define CHECK_CA_WARN(message) (err == noErr)
#define mp_mutex_lock(p) ((void)(p))
#define mp_mutex_unlock(p) ((void)(p))
#define mp_cond_broadcast(p) ((void)(p))
#define mp_thread_join(p) ((void)(p))
#define mp_cond_destroy(p) ((void)(p))
#define mp_mutex_destroy(p) ((void)(p))
static char *mp_tag_str(uint32_t v) { (void)v; return "fake"; }
static bool af_fmt_is_pcm(int format) { return format == 1; }
static int64_t av_rescale(int64_t a, int64_t b, int64_t c) { return a * b / c; }
static void talloc_free(void *p) {
    if (p == owner) {
        free(owner->log);
        free(owner->priv);
        owner = NULL;
    }
    free(p);
}
static OSStatus ca_select_device(struct ao *ao, char *name, AudioDeviceID *device) {
    (void)ao; (void)name; *device = 123;
    return is_case("device") ? -50 : noErr;
}
static bool ca_init_chmap(struct ao *ao, AudioDeviceID id) {
    (void)ao; (void)id; return !is_case("chmap") && !is_case("physical-format-failure");
}
static void ca_fill_asbd(struct ao *ao, AudioStreamBasicDescription *asbd) {
    (void)ao; memset(asbd, 0, sizeof(*asbd));
}
static AudioChannelLayout *ca_get_acl(struct ao *ao, size_t *size) {
    (void)ao; *size = sizeof(AudioChannelLayout); return calloc(1, *size);
}
static void init_physical_format(struct ao *ao) { ao->priv->original_asbd.mFormatID = 1; }
static OSStatus restore_format(AudioStreamID id, int property, void *asbd) {
    (void)id; (void)property; (void)asbd; restored++; return noErr;
}
#define CA_SET(id, property, data) restore_format(id, property, data)
static void reinit_latency(struct ao *ao) { ao->priv->hw_latency_ns = 100; latency_calls++; }
static void ao_hotplug_event(struct ao *ao) { log_touch(ao); callbacks++; }
static OSStatus render_cb_lpcm(void *ctx, AudioUnitRenderActionFlags *flags,
                              const AudioTimeStamp *ts, UInt32 bus,
                              UInt32 frames, AudioBufferList *buffers) {
    (void)ctx; (void)flags; (void)ts; (void)bus; (void)frames; (void)buffers; abort();
}

struct fake_unit { bool initialized; };
AudioComponent AudioComponentFindNext(AudioComponent previous, const AudioComponentDescription *description) {
    (void)previous; (void)description;
    return is_case("component") ? NULL : (AudioComponent)(uintptr_t)1;
}
OSStatus AudioComponentInstanceNew(AudioComponent component, AudioComponentInstance *unit) {
    (void)component;
    if (is_case("unit-new")) return -50;
    *unit = (AudioComponentInstance)calloc(1, sizeof(struct fake_unit)); live_units++; return noErr;
}
OSStatus AudioUnitInitialize(AudioUnit unit) {
    assert(unit);
    if (is_case("unit-init")) return -50;
    ((struct fake_unit *)unit)->initialized = true; initialized_units++; return noErr;
}
OSStatus AudioUnitUninitialize(AudioUnit unit) {
    assert(unit);
    if (((struct fake_unit *)unit)->initialized) initialized_units--;
    ((struct fake_unit *)unit)->initialized = false; return noErr;
}
OSStatus AudioComponentInstanceDispose(AudioComponentInstance unit) {
    assert(unit); assert(!((struct fake_unit *)unit)->initialized);
    live_units--; disposed++; free(unit); return noErr;
}
OSStatus AudioOutputUnitStop(AudioUnit unit) {
    assert(unit); assert(((struct fake_unit *)unit)->initialized); return noErr;
}
OSStatus AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID property,
                             AudioUnitScope scope, AudioUnitElement element,
                             const void *data, UInt32 size) {
    (void)scope; (void)element; (void)data; (void)size; assert(unit);
    if ((is_case("unit-property") && property == kAudioUnitProperty_StreamFormat) ||
        (is_case("unit-device") && property == kAudioOutputUnitProperty_CurrentDevice) ||
        (is_case("unit-map") && property == kAudioOutputUnitProperty_ChannelMap) ||
        (is_case("unit-callback") && property == kAudioUnitProperty_SetRenderCallback)) return -50;
    return noErr;
}
struct listener { AudioObjectPropertyListenerProc callback; void *context; };
static struct listener listeners[2];
static int listener_index(const AudioObjectPropertyAddress *address) {
    return address->mSelector == kAudioHardwarePropertyDevices ? 0 : 1;
}
OSStatus AudioObjectAddPropertyListener(AudioObjectID id, const AudioObjectPropertyAddress *address,
                                       AudioObjectPropertyListenerProc callback, void *context) {
    (void)id;
    int i = listener_index(address);
    if ((i == 0 && (is_case("listener-first") || is_case("hotplug-first"))) ||
        (i == 1 && (is_case("listener-second") || is_case("hotplug-partial") ||
                    is_case("retry-registration")))) return -50;
    assert(!listeners[i].callback);
    listeners[i] = (struct listener){callback, context}; added++; return noErr;
}
OSStatus AudioObjectRemovePropertyListener(AudioObjectID id, const AudioObjectPropertyAddress *address,
                                          AudioObjectPropertyListenerProc callback, void *context) {
    (void)id;
    int i = listener_index(address);
    assert(listeners[i].callback == callback && listeners[i].context == context);
    listeners[i] = (struct listener){0}; removed++; return noErr;
}
static void fire_device_change(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDevices, 0, 0};
    for (int i = 0; i < 2; i++) {
        if (listeners[i].callback) listeners[i].callback(1, 1, &address, listeners[i].context);
    }
}
/* PRODUCTION_FUNCTIONS */

int main(int argc, char **argv) {
    assert(argc == 3);
    scenario = argv[1];
    bool baseline = strcmp(argv[2], "original") == 0;
    owner = calloc(1, sizeof(*owner));
    owner->priv = calloc(1, sizeof(*owner->priv));
    owner->log = calloc(1, sizeof(*owner->log));
    owner->log->alive = 1; owner->format = 1; owner->samplerate = 48000;
    struct ao_driver driver = {.uninit = uninit}; owner->driver = &driver;
    if (is_case("exclusive")) owner->init_flags = AO_INIT_EXCLUSIVE;
    if (is_case("physical-format") || is_case("physical-format-failure"))
        owner->priv->change_physical_format = true;
    bool hotplug = strncmp(scenario, "hotplug-", 8) == 0 || is_case("retry-registration");
    int result = hotplug ? hotplug_init(owner) : init(owner);
    if (result < 0) {
        if (!baseline) {
            assert(added == removed);
            assert(owner->priv->hotplug_cb_registration_times == 0);
            assert(live_units == 0 && initialized_units == 0);
        }
        if (is_case("retry-registration")) {
            scenario = "hotplug-success";
            assert(hotplug_init(owner) == 0);
            fire_device_change(); assert(callbacks == 2);
            hotplug_uninit(owner);
        }
    } else {
        assert(added == 2 && removed == 0);
        owner->driver_initialized = !hotplug;
        fire_device_change(); assert(callbacks == 2);
        if (!hotplug) assert(latency_calls == 3);
        if (is_case("refcount")) {
            assert(register_hotplug_cb(owner)); assert(added == 2);
            unregister_hotplug_cb(owner); assert(removed == 0);
            fire_device_change(); assert(callbacks == 4);
        }
        if (hotplug) hotplug_uninit(owner);
        if (is_case("idle-work")) owner->priv->idle_work = dispatch_block_create(0, ^{ abort(); });
        if (is_case("repeated-cleanup")) {
            uninit(owner); uninit(owner); owner->driver_initialized = false;
        }
    }
    // This is production buffer.c ao_uninit, including its driver_initialized guard.
    ao_uninit(owner);
    // Baseline reproduces hotplug_cb use-after-free here, without any real HAL.
    fire_device_change();
    assert(added == removed && live_units == 0 && initialized_units == 0);
    if (is_case("physical-format") || is_case("physical-format-failure")) assert(restored == 1);
    puts("lifecycle safe");
}
