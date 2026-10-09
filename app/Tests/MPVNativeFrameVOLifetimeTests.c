/* Inert ownership fixture. ACTUAL_NATIVE_METHODS is replaced mechanically by
 * pinned/current production methods. These doubles record resource operations;
 * they do not implement a second transition policy or claim real GPU safety. */
#include <assert.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "vortx_apple_frame.h"

#define MP_ARRAY_SIZE(a) ((int)(sizeof(a) / sizeof((a)[0])))
#define VO_PASS_PERF_MAX 2
#define PL_HANDLE_MTL_TEX 1
#define SUBBITMAP_LIBASS 0
#define SUBBITMAP_BGRA 1
#define mp_assert assert
#define TA_FREEP(p) (*(p) = NULL)
#define talloc_free(p) ((void)(p))
typedef pthread_mutex_t mp_mutex;
#define mp_mutex_init(p) assert(!pthread_mutex_init((p), NULL))
#define mp_mutex_destroy(p) assert(!pthread_mutex_destroy(p))
#define mp_mutex_lock(p) assert(!pthread_mutex_lock(p))
#define mp_mutex_unlock(p) assert(!pthread_mutex_unlock(p))

static bool foreground = true;
static int gpu_calls, background_gpu_calls, gpu_creates, gpu_destroys;
static int device_creates, device_destroys, mapper_destroys, decoder_allocations;
static int redraw_options, reconfigs, flips, backend_wakeups;
static int borrowed_log_failures, icc_closes, cache_closes;
static int fail_create, eligibility = MPV_VORTX_FRAME_READY;
static bool fail_reconfig, detach_during_destroy, detach_during_reconfig;
static uint64_t active_cookie;
static mpv_vortx_apple_frame_session *active_session;
static void gpu_operation(void) { gpu_calls++; if (!foreground) background_gpu_calls++; }
static int token;
static void *handle(void) { return &token; }

struct vo;
struct ra_ctx;
struct ra_fns { const char *name; void (*wakeup)(struct ra_ctx *); };
struct ra_ctx { struct ra_fns *fns; };
struct gpu { struct { int tex; } import_caps; };
struct gpu_ctx { struct ra_ctx *ra_ctx; void *pllog; struct gpu *gpu; void *swapchain; };
struct hw_driver { const char *name; };
struct ra_hwdec { struct ra_ctx *ra_ctx; struct hw_driver *driver; void *device_ref; };
struct ra_hwdec_ctx {
    void *log, *global;
    struct ra_ctx *ra_ctx;
    struct ra_hwdec *hwdecs[2];
    int num_hwdecs;
};
enum { IMGFMT_VIDEOTOOLBOX = 1, PL_COLOR_SYSTEM_DOLBYVISION,
       PL_COLOR_SYSTEM_BT_709, PL_COLOR_PRIM_BT_709, PL_COLOR_TRC_BT_1886,
       PL_COLOR_TRC_SRGB, MP_IMGFIELD_INTERLACED };
struct mp_image_params {
    struct { int sys; } repr;
    struct { int primaries, transfer; } color;
    struct { int x0, y0, x1, y1; } crop;
    bool vflip;
    int rotate, stereo3d, p_w, p_h;
};
struct mp_image { int imgfmt, w, h, fields; double pts;
    void *dovi, *enhancement_layer, *film_grain, *icc_profile, *planes[4];
    struct mp_image_params params;
};
struct vo_frame { struct vortx_frame_stamp vortx_stamp; struct mp_image *current;
    bool vortx_captions_required, display_synced; double vortx_media_rate; int64_t pts;
};
struct icc_opts { bool cache, profile_auto, use_embedded; char *cache_dir, *profile; };
struct gl_video_opts { bool shader_cache; char *shader_cache_dir; struct icc_opts *icc_opts;
    char *hwdec_interop; char **user_shaders; bool deband, interpolation; double unsharp, gamma;
};
struct lut { void *lut; char *opt; };
struct gl_next_opts { struct lut image_lut, lut, target_lut; char **raw_opts; };
struct mp_csp_params { double brightness, contrast, hue, saturation, gamma; };
#define MP_CSP_PARAMS_DEFAULTS {.contrast = 1, .saturation = 1, .gamma = 1}
static void mp_csp_equalizer_state_get(void *state, struct mp_csp_params *eq)
{ (void)state; (void)eq; }
typedef uint32_t OSType;
typedef const void *CFTypeRef;
typedef struct pixel { OSType format; CFTypeRef primaries, matrix, transfer; } *CVPixelBufferRef;
enum { kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange = 10,
       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange };
static const char *kCVImageBufferColorPrimariesKey = "primaries";
static const char *kCVImageBufferYCbCrMatrixKey = "matrix";
static const char *kCVImageBufferTransferFunctionKey = "transfer";
static const char *kCVImageBufferColorPrimaries_ITU_R_709_2 = "p709";
static const char *kCVImageBufferYCbCrMatrix_ITU_R_709_2 = "m709";
static const char *kCVImageBufferTransferFunction_ITU_R_709_2 = "t709";
static OSType CVPixelBufferGetPixelFormatType(CVPixelBufferRef p) { return p->format; }
static CFTypeRef CVBufferGetAttachment(CVPixelBufferRef p, const char *key, void *mode)
{
    (void)mode;
    if (!strcmp(key, "primaries")) return p->primaries;
    if (!strcmp(key, "matrix")) return p->matrix;
    return p->transfer;
}
static bool CFEqual(CFTypeRef a, CFTypeRef b) { return !strcmp(a, b); }
struct m_config_cache { void *opts; };
struct cache { void *cache; char *dir; };
struct borrowed_log { bool alive; int borrowers; };
struct ra_ctx_opts { int unused; };
struct frame_info { struct { void *shader; } info[VO_PASS_PERF_MAX]; };
struct user_hook { void *hook; char *path; };
struct mpv_global { void *client_api; };
struct priv {
    mpv_vortx_apple_frame_session *vortx_frames;
    struct vortx_gpu_gate vortx_allocations;
    bool vortx_gate_initialized, vortx_dr_initialized, vortx_moltenvk, vortx_retired;
    struct mp_image *vortx_last_image;
    struct vo_frame vortx_last_frame;
    struct gpu_ctx *context;
    struct ra_ctx *ra_ctx;
    struct gpu *gpu;
    void *pllog, *sw, *log, *stats;
    struct mpv_global *global;
    struct ra_hwdec_ctx hwdec_ctx;
    void *hwdec_mapper, *el_hwdec_mapper;
    void *hwdec_timer, *el_hwdec_timer, *sw_upload_timer;
    struct { int count; } hwdec_perf, sw_upload_perf;
    mp_mutex dr_lock;
    int num_dr_buffers;
    void *queue, *rr, *pars, *osd_fmt[2];
    struct { struct { void *tex, *parts; } entries[2]; } osd_state;
    void **sub_tex;
    int num_sub_tex;
    struct user_hook *user_hooks;
    int num_user_hooks;
    void *hooks;
    struct frame_info perf_fresh, perf_redraw;
    bool frame_pending, want_reset, flush_cache, is_interpolated, paused;
    uint64_t last_id, osd_sync;
    double last_pts;
    struct m_config_cache *opts_cache, *next_opts_cache;
    struct gl_next_opts *next_opts;
    void *video_eq, *icc_profile;
    char *icc_path;
    struct cache shader_cache, icc_cache;
};
struct vo { struct priv *priv; struct mpv_global *global; void *log, *hwdec_devs;
            void *target_params; bool want_redraw; mp_mutex params_mutex; };
static int gl_video_conf, gl_next_conf, ra_ctx_conf;
static struct icc_opts icc_options = {.cache = true, .use_embedded = true};
static struct gl_video_opts options = {.icc_opts = &icc_options, .shader_cache = true, .gamma = 1};
static struct gl_next_opts next_options;
static struct m_config_cache option_cache = {&options}, next_cache = {&next_options};
static struct hw_driver vt_driver = {"videotoolbox"}, other_driver = {"vulkan"};
static struct ra_hwdec vt_owner, other_owner = {.driver = &other_driver};
static int device_identity;

static void wake_backend(struct ra_ctx *ctx) { assert(ctx); backend_wakeups++; }
static struct ra_fns moltenvk_fns = {"moltenvk", NULL}, other_fns = {"other", wake_backend};
static struct gpu_ctx contexts[32];
static struct ra_ctx ras[32];
static struct gpu gpus[32];
static struct borrowed_log logs[32];
static struct gpu_ctx *gpu_ctx_create(struct vo *vo, struct ra_ctx_opts *opts)
{
    (void)vo; (void)opts;
    gpu_operation();
    if (fail_create == 1) return NULL;
    int n = gpu_creates++;
    assert(n < 32);
    ras[n].fns = &moltenvk_fns;
    gpus[n].import_caps.tex = PL_HANDLE_MTL_TEX;
    logs[n] = (struct borrowed_log){.alive = true};
    contexts[n] = (struct gpu_ctx){&ras[n], &logs[n], &gpus[n], handle()};
    return &contexts[n];
}
static void gpu_ctx_destroy(struct gpu_ctx **ctx)
{
    if (!*ctx) return;
    /* Models the proven terminal QueueWaitIdle fresh-submit entrance. */
    gpu_operation(); gpu_destroys++;
    struct borrowed_log *log = (*ctx)->pllog;
    if (log->borrowers) borrowed_log_failures++;
    log->alive = false;
    *ctx = NULL;
    if (detach_during_destroy)
        mpv_vortx_apple_frame_detach(active_session, active_cookie);
}
static void destroy_resource(void **resource)
{
    if (*resource) gpu_operation();
    *resource = NULL;
}
#define pl_gpu_finish(gpu) do { if (gpu) gpu_operation(); } while (0)
#define pl_queue_destroy(p) destroy_resource((void **)(p))
#define pl_tex_destroy(gpu, p) destroy_resource((void **)(p))
#define pl_mpv_user_shader_destroy(p) destroy_resource((void **)(p))
#define pl_renderer_destroy(p) destroy_resource((void **)(p))
#define pl_options_free(p) destroy_resource((void **)(p))
#define pl_lut_free(p) TA_FREEP(p)
static void pl_icc_close(void **profile)
{
    if (!*profile) return;
    struct borrowed_log *log = *profile;
    if (!log->alive) borrowed_log_failures++;
    log->borrowers--; icc_closes++; *profile = NULL;
}
#define pl_shader_info_deref(p) TA_FREEP(p)
static void timer_pool_destroy(void *timer) { if (timer) gpu_operation(); }
static void ra_hwdec_mapper_free(void **mapper)
{
    if (*mapper) { gpu_operation(); mapper_destroys++; }
    *mapper = NULL;
}
static void ra_hwdec_ctx_uninit(struct ra_hwdec_ctx *ctx)
{
    if (ctx->num_hwdecs) device_destroys++;
    ctx->num_hwdecs = 0;
}
static void hwdec_devices_set_loader(void *devs,
    void (*loader)(void *, void *), void *ctx) { (void)devs; (void)loader; (void)ctx; }
static void hwdec_devices_destroy(void *devs) { assert(devs == &device_identity); }
static void *hwdec_devices_create(void) { device_creates++; return &device_identity; }
static void load_hwdec_api(void *ctx, void *params) { (void)ctx; (void)params; }
static void ra_hwdec_ctx_init(struct ra_hwdec_ctx *ctx, void *devs, char *interop, bool all)
{
    (void)interop; (void)all;
    vt_owner = (struct ra_hwdec){ctx->ra_ctx, &vt_driver, devs};
    ctx->hwdecs[0] = &vt_owner;
    ctx->num_hwdecs = 1;
}
static struct m_config_cache *m_config_cache_alloc(void *p, void *global, void *conf)
{ (void)p; (void)global; return conf == &gl_video_conf ? &option_cache : &next_cache; }
static void *mp_csp_equalizer_create(void *p, void *global) { (void)p; (void)global; return handle(); }
static void *stats_ctx_create(void *p, void *global, const char *name)
{ (void)p; (void)global; (void)name; return handle(); }
static struct ra_ctx_opts *mp_get_config_group(void *vo, void *global, void *conf)
{ (void)vo; (void)global; (void)conf; static struct ra_ctx_opts opts; return &opts; }
static void update_ra_ctx_options(struct vo *vo, struct ra_ctx_opts *opts)
{ (void)vo; (void)opts; }
static void cache_init(struct vo *vo, struct cache *cache, int size, char *path)
{
    (void)size; (void)path;
    struct borrowed_log *log = vo->priv->pllog;
    assert(log->alive); log->borrowers++; cache->cache = log;
    cache->dir = "inert-cache-no-filesystem";
}
static void cache_uninit(struct priv *p, struct cache *cache)
{
    (void)p;
    if (!cache->cache) return;
    struct borrowed_log *log = cache->cache;
    if (!log->alive) borrowed_log_failures++;
    log->borrowers--; cache_closes++; cache->cache = NULL;
}
static void pl_gpu_set_cache(struct gpu *gpu, void *cache) { (void)gpu; (void)cache; gpu_operation(); }
static void *pl_renderer_create(void *log, struct gpu *gpu)
{ (void)log; (void)gpu; gpu_operation(); return fail_create == 2 ? NULL : handle(); }
static void *pl_queue_create(struct gpu *gpu) { (void)gpu; gpu_operation(); return handle(); }
static void *pl_find_named_fmt(struct gpu *gpu, const char *name) { (void)gpu; (void)name; return handle(); }
static void *pl_options_alloc(void *log) { (void)log; return handle(); }
static void update_render_options(struct vo *vo) { (void)vo; gpu_operation(); redraw_options++; }
static void update_options(struct vo *vo) { (void)vo; gpu_operation(); }
static void mp_image_unrefp(struct mp_image **image) { *image = NULL; }
static mpv_vortx_apple_frame_session *mp_client_vortx_frames(void *client) { return client; }
static int vortx_frame_eligibility(struct vo *vo, struct vo_frame *frame)
{ (void)vo; (void)frame; return eligibility; } // lifecycle injection, real admission below
static int reconfig(struct vo *vo, void *params)
{
    (void)vo; (void)params; gpu_operation(); reconfigs++;
    if (detach_during_reconfig)
        mpv_vortx_apple_frame_detach(active_session, active_cookie);
    return fail_reconfig ? -1 : 0;
}
static void flip_page(struct vo *vo) { gpu_operation(); flips++; vo->priv->frame_pending = false; }
static struct mp_image *get_image_unguarded(struct vo *vo, int fmt, int w, int h, int align, int flags)
{
    (void)vo; (void)fmt; (void)w; (void)h; (void)align; (void)flags;
    static struct mp_image image;
    gpu_operation(); decoder_allocations++; return &image;
}
static int create_gpu_resources(struct vo *vo, bool restoring);
static void destroy_gpu_resources(struct vo *vo, bool preserve_vt);
static void uninit(struct vo *vo);

/* ACTUAL_NATIVE_METHODS */

static int checks;
#define CHECK(value, name) do { if (!(value)) { \
    fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, name); return 1; \
} printf("PASS %s\n", name); checks++; } while (0)
static void receive(void *ctx, mpv_vortx_apple_frame_session *s,
                    const struct mpv_vortx_apple_frame *frame)
{ (void)ctx; (void)s; (void)frame; }
static void seed_frame(struct priv *p)
{
    static struct mp_image image;
    p->vortx_last_image = &image;
    p->vortx_last_frame.current = &image;
    p->vortx_last_frame.vortx_stamp = vortx_frame_stamp(active_session);
}
static uint64_t subscribe(void)
{
    return active_cookie = vortx_frame_subscribe(active_session, 123, receive, NULL, NULL);
}

int main(void)
{
    active_session = vortx_frame_create();
    vortx_frame_source(active_session, true);
    subscribe();
    struct mpv_global global = {.client_api = active_session};
    struct priv p = {0};
    struct vo vo = {.priv = &p, .global = &global, .params_mutex = PTHREAD_MUTEX_INITIALIZER};
    CHECK(preinit(&vo) == 0 && p.context && p.vortx_moltenvk,
          "actual preinit creates initial foreground GPU and immutable MoltenVK marker");
    struct pixel pixel = {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVImageBufferTransferFunction_ITU_R_709_2};
    struct mp_image sample = {.imgfmt = IMGFMT_VIDEOTOOLBOX, .w = 1920, .h = 1080,
        .pts = 123.25, .planes = {[3] = &pixel}, .params = {
            .repr = {PL_COLOR_SYSTEM_BT_709},
            .color = {PL_COLOR_PRIM_BT_709, PL_COLOR_TRC_BT_1886}, .p_w = 1, .p_h = 1}};
    struct vo_frame sample_frame = {.current = &sample, .pts = 1000000, .vortx_media_rate = 1.25};
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_READY,
          "actual admission allows ordinary SDR VT with default use-absent-ICC permission");
    sample.icc_profile = handle();
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_TRANSFORM_REQUIRED,
          "actual embedded ICC transform is not silently bypassed");
    icc_options.use_embedded = false;
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_READY,
          "explicit ignore-embedded-ICC setting does not reject unused metadata");
    sample.icc_profile = NULL; icc_options.use_embedded = true;
    icc_options.profile = "profile.icc";
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_TRANSFORM_REQUIRED,
          "configured custom ICC refuses raw-pixel handoff");
    icc_options.profile = NULL; icc_options.profile_auto = true;
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_TRANSFORM_REQUIRED,
          "auto ICC transform request refuses raw-pixel handoff");
    icc_options.profile_auto = false; p.icc_profile = handle();
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_TRANSFORM_REQUIRED,
          "already active ICC refuses raw-pixel handoff");
    p.icc_profile = NULL; sample.dovi = handle();
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_DOLBY_VISION,
          "actual DV metadata refuses base-layer-only PiP");
    sample.dovi = NULL; sample.enhancement_layer = handle();
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_DOLBY_VISION,
          "actual FEL enhancement layer refuses raw-frame handoff");
    sample.enhancement_layer = NULL; sample_frame.vortx_captions_required = true;
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_CAPTIONS_REQUIRED,
          "selected native captions remain mandatory through admission");
    sample_frame.vortx_captions_required = false; sample_frame.vortx_media_rate = -1;
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_UNSUPPORTED_TIMING,
          "reverse scheduled direction cannot masquerade as forward sample-buffer time");
    sample_frame.vortx_media_rate = 1.25; sample.film_grain = handle();
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_TRANSFORM_REQUIRED,
          "required film grain is not discarded to enable PiP");
    sample.film_grain = NULL; pixel.transfer = NULL;
    CHECK(vortx_native_eligibility(&vo, &sample_frame) == MPV_VORTX_FRAME_UNSUPPORTED_COLOR,
          "missing actual color attachment refuses guessed color output");
    pixel.transfer = kCVImageBufferTransferFunction_ITU_R_709_2;
    void *registry = vo.hwdec_devs, *device = vt_owner.device_ref;
    struct ra_hwdec *owner = p.hwdec_ctx.hwdecs[0];
    int initial_device_creates = device_creates;
    seed_frame(&p);
    struct vortx_frame_mode_request request = {active_session, active_cookie, true, false, 0};
    CHECK(get_image(&vo, 0, 1, 1, 1, 0) && decoder_allocations == 1,
          "actual decoder wrapper admits ordinary foreground allocation");
    p.num_dr_buffers = 1;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_GPU_BUSY && p.context &&
          vortx_gpu_gate_enter(&p.vortx_allocations),
          "existing direct-render buffer refuses retirement and restores allocation gate");
    vortx_gpu_gate_leave(&p.vortx_allocations);
    p.num_dr_buffers = 0;
    p.hwdec_ctx.hwdecs[1] = &other_owner;
    p.hwdec_ctx.num_hwdecs = 2;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_NOT_VIDEOTOOLBOX && p.context,
          "extra Vulkan/device owner refuses preservation even with a VT current frame");
    p.hwdec_ctx.num_hwdecs = 1;
    request.captions_required = true;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_CAPTIONS_REQUIRED && p.context,
          "current core-selected captions refuse a stale caption-free paused frame");
    request.captions_required = false;
    eligibility = MPV_VORTX_FRAME_DOLBY_VISION;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_DOLBY_VISION && p.context,
          "native eligibility refusal cannot partially retire GPU");
    eligibility = MPV_VORTX_FRAME_READY;
    // Exercise lifetime cleanup independently of the separately tested pixel
    // admission. Both objects retain borrowed log pointers in real libplacebo.
    p.icc_profile = p.pllog; p.icc_path = "inert-profile";
    ((struct borrowed_log *)p.pllog)->borrowers++;
    p.hwdec_mapper = handle(); p.hwdec_timer = handle(); p.frame_pending = true;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_READY && !p.context &&
          !p.gpu && !p.ra_ctx && p.vortx_retired && !p.queue && !p.rr &&
          mapper_destroys == 1 && flips == 1,
          "headless acknowledgement follows pending presentation and complete GPU retirement");
    CHECK(icc_closes == 1 && cache_closes == 2 && !p.icc_profile && !p.icc_path &&
          !p.shader_cache.cache && !p.icc_cache.cache && !borrowed_log_failures,
          "ICC and shader caches close before borrowed GPU log dies and invalidate reload paths");
    CHECK(vo.hwdec_devs == registry && p.hwdec_ctx.hwdecs[0] == owner &&
          vt_owner.device_ref == device && !vt_owner.ra_ctx && !p.hwdec_ctx.ra_ctx &&
          device_creates == initial_device_creates && device_destroys == 0,
          "same VT registry owner and device reference survive full GPU retirement");
    int before = gpu_calls;
    foreground = false;
    vortx_frame_set_foreground(active_session, false);
    CHECK(!get_image(&vo, 0, 1, 1, 1, 0) && gpu_calls == before,
          "closed decoder gate forbids all new GPU allocation while headless");
    struct ra_ctx trap_ra = {.fns = &other_fns};
    p.ra_ctx = &trap_ra; // a dereference would call the observable trap backend
    wakeup(&vo);
    p.ra_ctx = NULL;
    CHECK(gpu_calls == before && backend_wakeups == 0,
          "immutable MoltenVK wakeup does not dereference retired RA context");
    request.headless = false;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_GPU_BUSY && !p.context,
          "restoration refuses missing foreground authority without GPU creation");
    struct priv fresh = {0}; struct vo fresh_vo = {.priv = &fresh, .global = &global};
    vortx_frame_source(active_session, false); vortx_frame_source(active_session, true);
    CHECK(preinit(&fresh_vo) < 0 && !fresh.context && gpu_calls == before,
          "fresh VO after source replacement cannot reset background authority");
    subscribe(); request.subscription = active_cookie;
    foreground = true; vortx_frame_set_foreground(active_session, true);
    seed_frame(&p);
    fail_create = 2;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_GPU_BUSY && !p.context &&
          p.vortx_retired && vo.hwdec_devs == registry && vt_owner.device_ref == device,
          "partial foreground recreation destroys new GPU only and retains exact VT identity");
    CHECK(!vortx_gpu_gate_enter(&p.vortx_allocations),
          "failed restoration never reopens decoder allocation");
    fail_create = 0;
    fail_reconfig = true;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_GPU_BUSY && !p.context &&
          p.vortx_retired && !vortx_gpu_gate_enter(&p.vortx_allocations),
          "foreground geometry failure retires partial GPU and leaves allocation closed");
    fail_reconfig = false;
    detach_during_reconfig = true;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_STALE_OWNER && !p.context &&
          p.vortx_retired && !vortx_gpu_gate_enter(&p.vortx_allocations) &&
          vo.hwdec_devs == registry && vt_owner.device_ref == device,
          "detach during final geometry rebuild denies late acknowledgement and stays retired");
    detach_during_reconfig = false;
    subscribe(); request.subscription = active_cookie;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_READY && p.context &&
          !p.vortx_retired && vt_owner.ra_ctx == p.ra_ctx && p.hwdec_ctx.ra_ctx == p.ra_ctx &&
          vo.hwdec_devs == registry && vt_owner.device_ref == device && vo.want_redraw &&
          device_creates == initial_device_creates && device_destroys == 0,
          "foreground restore rebinds both RA references without new VT owner or decoder");
    CHECK(p.shader_cache.cache == p.pllog && p.icc_cache.cache == p.pllog &&
          !borrowed_log_failures, "restored caches borrow only the recreated live log");
    CHECK(get_image(&vo, 0, 1, 1, 1, 0) && decoder_allocations == 2,
          "successful complete restoration alone reopens decoder allocation");
    request.headless = true;
    seed_frame(&p);
    detach_during_destroy = true;
    CHECK(vortx_frame_mode(&vo, &request) == MPV_VORTX_FRAME_STALE_OWNER && !p.context &&
          p.vortx_retired && !vortx_gpu_gate_enter(&p.vortx_allocations),
          "late owner cancellation denies acknowledgement without reopening retired GPU");
    detach_during_destroy = false;
    foreground = false; vortx_frame_set_foreground(active_session, false);
    before = gpu_calls;
    uninit(&vo);
    CHECK(gpu_calls == before && background_gpu_calls == 0 && device_destroys == 1,
          "actual terminal cleanup while headless releases VT and submits zero GPU work");
    mp_mutex_destroy(&vo.params_mutex);

    /* Contrast the actual original terminal method. This is not a fabricated
     * old PiP mode: it proves why retaining an idle context until background
     * destruction was not a valid implementation of this new feature. */
    foreground = true; vortx_frame_set_foreground(active_session, true);
    struct priv old = {0}; struct vo old_vo = {.priv = &old, .global = &global,
                                            .params_mutex = PTHREAD_MUTEX_INITIALIZER};
    CHECK(preinit(&old_vo) == 0, "baseline teardown fixture has actual initialized GPU resources");
    foreground = false;
    before = background_gpu_calls;
    baseline_uninit(&old_vo);
    CHECK(background_gpu_calls > before,
          "original uninit invokes fresh GPU operations if context survives into background");
    vortx_gpu_gate_destroy(&old.vortx_allocations); // absent from original source
    mp_mutex_destroy(&old_vo.params_mutex);
    struct ra_ctx other_ra = {.fns = &other_fns};
    struct priv other_p = {.ra_ctx = &other_ra};
    struct vo other_vo = {.priv = &other_p};
    wakeup(&other_vo);
    CHECK(backend_wakeups == 1, "unrelated non-MoltenVK backend wakeup remains unchanged");
    vortx_frame_close(active_session); mpv_vortx_apple_frame_release(active_session);
    printf("RESULT %d PASS (actual lifetime methods; inert GPU/VT only)\n", checks);
    return 0;
}
