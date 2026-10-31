#ifndef VORTX_PUBLIC_REFERENCE_FIXTURE_H
#define VORTX_PUBLIC_REFERENCE_FIXTURE_H
#include <stdbool.h>
#include "mpv/client.h"
#include "sub/osd.h"
struct MPContext;
struct dec_sub;
/* Fixture executable only. Never placed in native production headers/SDK. */
struct MPContext *vpr_real_core(mpv_handle *client);
void vpr_decoder_lock(struct dec_sub *decoder);
void vpr_decoder_unlock(struct dec_sub *decoder);
void vpr_arm_reader(struct dec_sub *decoder);
void vpr_release_reader(struct dec_sub *decoder);
bool vpr_reader_selected(void);
struct sub_bitmap_list *vpr_render(struct osd_state *osd, double pts);
#endif
