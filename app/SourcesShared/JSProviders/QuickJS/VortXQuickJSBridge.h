#ifndef VORTX_QUICKJS_BRIDGE_H
#define VORTX_QUICKJS_BRIDGE_H

#include <stdint.h>

/*
 * Narrow C boundary around the pinned QuickJS interpreter. Swift owns URLSession, policy, and all app state;
 * this layer owns only one disposable interpreter instance. Every returned string is malloc-owned and must be
 * released with VortXQuickJSFree.
 */
char *VortXQuickJSRun(const char *crypto_source, const char *cheerio_source, const char *preamble_source,
                      const char *provider_source, const char *params_json, const char *settings_json,
                      const char *provider_id, void *host, volatile int32_t *cancelled,
                      int64_t deadline_millis, int *result_code);
void VortXQuickJSFree(void *value);

#endif
