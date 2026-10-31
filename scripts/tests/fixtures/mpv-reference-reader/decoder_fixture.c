/* Exact whole current decoder TU. The observer delegates EVERY mutex call to
 * the real native mutex. It observes the real render reader's lock attempt;
 * no subtitle decode, source predicate, bitmap or OSD policy is replaced. */
#include <stdatomic.h>
#include "public_fixture.h"
#include "osdep/threads.h"
static int vpr_native_lock(mp_mutex *mutex) { return mp_mutex_lock(mutex); }
static int vpr_observed_lock(mp_mutex *mutex);
static _Atomic(mp_mutex *) vpr_expected;
static atomic_bool vpr_selected;
static _Thread_local bool vpr_is_reader;
#undef mp_mutex_lock
#define mp_mutex_lock vpr_observed_lock
#ifndef VPR_ACTUAL_DEC_SUB_C
#error "Root must bind the exact current whole sub/dec_sub.c source"
#endif
#include VPR_ACTUAL_DEC_SUB_C
#undef mp_mutex_lock
#define mp_mutex_lock vpr_native_lock
static int vpr_observed_lock(mp_mutex *mutex)
{
    if (vpr_is_reader && mutex == atomic_load_explicit(&vpr_expected, memory_order_seq_cst))
        atomic_store_explicit(&vpr_selected, true, memory_order_seq_cst);
    return vpr_native_lock(mutex);
}
void vpr_decoder_lock(struct dec_sub *decoder) { mp_mutex_lock(&decoder->lock); }
void vpr_decoder_unlock(struct dec_sub *decoder) { mp_mutex_unlock(&decoder->lock); }
void vpr_arm_reader(struct dec_sub *decoder)
{
    vpr_decoder_lock(decoder);
    atomic_store_explicit(&vpr_selected, false, memory_order_seq_cst);
    atomic_store_explicit(&vpr_expected, &decoder->lock, memory_order_seq_cst);
}
void vpr_release_reader(struct dec_sub *decoder)
{
    atomic_store_explicit(&vpr_expected, NULL, memory_order_seq_cst);
    vpr_decoder_unlock(decoder);
}
bool vpr_reader_selected(void)
{
    return atomic_load_explicit(&vpr_selected, memory_order_seq_cst);
}
struct sub_bitmap_list *vpr_render(struct osd_state *osd, double pts)
{
    const bool formats[SUBBITMAP_COUNT] = {
        [SUBBITMAP_LIBASS] = true, [SUBBITMAP_BGRA] = true,
    };
    vpr_is_reader = true;
    struct sub_bitmap_list *images = osd_render(osd,
        (struct mp_osd_res){.w = 640, .h = 360, .display_par = 1}, pts,
        OSD_DRAW_SUB_ONLY, formats);
    vpr_is_reader = false;
    return images;
}
