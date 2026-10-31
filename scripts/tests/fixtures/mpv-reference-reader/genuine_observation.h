#ifndef VORTX_GENUINE_READER_OBSERVATION_H
#define VORTX_GENUINE_READER_OBSERVATION_H
#include <stdbool.h>
/* Fixture-only observers; never installed in a native component or public API.
 * State is process-local and only observes the one synchronous fixture read. */
bool genuine_body_phase_active(void);
bool genuine_body_phase_set(bool value);
void genuine_body_wait_observed(void);
unsigned genuine_foreign_demux_wakes(void *consumer);
#endif
