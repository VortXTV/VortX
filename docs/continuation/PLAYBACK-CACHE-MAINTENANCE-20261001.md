# Cache-maintenance EOF and paused recovery

The retained build-252 Apple TV diagnostic contains 11,085 lines. All ranges were read,
including heartbeat records. It documents one HTTP/Easynews/libmpv session, not an AVPlayer,
Dolby-remux or local NNTP test. The repeated sequence below is an application cache-lifecycle
failure; these records do not establish a provider outage.

| Trigger | Position before maintenance | Observed failure |
| --- | --- | --- |
| Memory warning with a buffered tail | 3685.974 / 3740.529 seconds | Cache empties, EOF, reopen at zero, missed high resume, another reopen around nine seconds. |
| Proactive pressure and a lower cache cap | 3693.815 seconds | The same EOF/reopen/failed-resume sequence repeats. |
| Background cache clamp | 3516.999 seconds | EOF and recovery use an obsolete earlier high resume target. |

The shipped mpv revision is `8c67647b50059406c5c0444903597281b81516cf`.
Its [command implementation](https://github.com/mpv-player/mpv/blob/8c67647b50059406c5c0444903597281b81516cf/player/command.c)
resets playback immediately for `drop-buffers`, whereas a seek queues delayed work. Combining
the commands does not make completed transport atomic. The
[demux implementation](https://github.com/mpv-player/mpv/blob/8c67647b50059406c5c0444903597281b81516cf/demux/demux.c)
also adopts runtime options on its own thread; reading an option back is not evidence that
the demuxer has already adopted it.

## Repair contract

- Keep the decoder intact until an exact low-level seek executes; do not issue a preceding
  standalone buffer drop.
- Capture the exact loaded owner, maintenance attempt, prior seekable-cache option,
  transport intent and low-level-seek counter. Hold the temporary option until settlement.
- Require owned event-time evidence, an increased counter and a compatible landing.
  One cached-restart reissue is allowed within the original deadline. Timeout is failure.
- Restore the prior option before replacement, explicit seeking, stop or cancellation can
  change ownership. An older callback cannot restore an option into a newer flight.
- A high-position reopen cannot settle at zero. A repair's forced pause is not the viewer's
  Pause choice. Paused target restoration requires the exact loaded replacement's duration
  and successful exact-seek admission; a slow open cannot consume the pending obligation.

The dependency-free policy and receipt suites cover all three diagnostic shapes, stale
attempts, option restoration, timeout, false zero landings, transport choice and slow paused
reopening. Apple app compilation is a separate gate. This is not native runtime or physical
playback acceptance: no runnable pinned host harness was established from the packaged
static archive.

The device retest must confirm actual cache-memory relief, low-level counter advancement,
restored option state, correct high-target landing and preserved Play/Pause choice without
synthetic EOF. The diagnostic's zero decoder/output-drop samples do not prove physical
frame cadence; presentation timing was unavailable in that session.
