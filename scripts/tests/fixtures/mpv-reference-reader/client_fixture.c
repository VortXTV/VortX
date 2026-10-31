/* Exact whole current client TU plus a typed fixture-only getter. The link
 * must omit its original player_client.c.o member; no duplicate fallback. */
#include "public_fixture.h"
#ifndef VPR_ACTUAL_CLIENT_C
#error "Root must bind the exact current whole player/client.c source"
#endif
#include VPR_ACTUAL_CLIENT_C
struct MPContext *vpr_real_core(mpv_handle *client)
{
    return client ? client->mpctx : NULL;
}
