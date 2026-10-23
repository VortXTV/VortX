# TV seek-track decorative motion

The TV player now passes the shared seek track an explicit motion-eligibility
value. Decorative motion is enabled only while the controls are shown, options
are closed, loading has not failed, playback is not paused, scrubbing is inactive,
and the effective Reduce Motion policy (system or app motion setting) is off.
The shared renderer still disables its timeline
for styles that are intrinsically static.

This changes only the `SeekBarTrack` constructor's `animated` argument. Progress,
buffered fraction, seeking, chapters, knob geometry, focus, colour arguments and
the shared renderer are unchanged. The control bar is already conditionally
mounted; this repair does not claim continuous hidden rendering was occurring.

## Retained regression contract

`scripts/prepare-tv-seek-track-motion.cjs` captures the complete owning TV/shared
sources, the test and the raw scrubber baseline before extraction. It extracts
the actual constructor, progress expressions, animated-style classification,
default and shared timeline-paused expression. Removing only the new argument
must restore the complete raw scrubber baseline byte-for-byte. Its `--verify`
mode checks owning, captured and generated source hashes without compiling.

`app/Tests/TVSeekTrackMotionTests.swift` runs 64 visibility/suppression masks over
14 styles, plus nine finite clamp cases: **905 cases in one source-unit
executable**. Colour, progress and buffered arguments are also checked. UI,
Theme and current-style selection are deterministic probes; no real preferences
are accessed.

The actual old-source negative compiled successfully and exited normally with
1,638 attributable failed assertions across those 905 cases. After the single
constructor change, a separately fresh Swift 6 strict-concurrency source-unit
compile and executable completed normally with all 905 cases passing. Both
attempts used low-priority, serial, jobs-1/threads-1 compilation, retained exact
inputs, owned deadlines/cleanup and before/after source/tool checks. The negative
remains a negative; it is not counted as a product pass.

This is a bounded Foundation source test, **not** actual SwiftUI typechecking,
Timeline scheduling, a tvOS app build, remote/focus acceptance or a measurement
of physical frame time, power or memory. No app was built, installed or launched
for this check. Those platform and performance gates remain separate.
