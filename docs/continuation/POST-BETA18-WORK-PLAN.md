# Work remaining after the Beta 18 source batch

This is the current implementation backlog, not a declaration of full Apple/Android parity.
The reviewed Beta 18 source is tagged at `c144b6895e956fbdd102dead8551accb52197576`.
Use the [release notes](../releases/0.4.0-beta.18.md) and actual release receipts for publication
status. Do not substitute the August runbooks, prototype branches or earlier binaries.

## 1. Playback first: collect a new affected-device receipt, then repair any remaining fault

- Install the exact Beta 18 package and exercise AVPlayer DV, direct HTTP and local NNTP separately.
  Include the previously failing add-on route and a comparison source for the same file.
- Cover high-position CW resume, a long pause, backward/forward seek, source/engine replacement,
  new-episode zero start, manual Next/Previous and consecutive automatic episodes.
- For cache maintenance, verify owned low-level-seek counter advancement, target-compatible landing,
  cache-option restoration, real memory relief and preservation of the viewer's pause/play choice.
  Command admission alone is not a successful cache-trim receipt.
- Correlate producer/read-ahead, decoder selection, actual frame-presentation evidence and HTTP/NNTP
  failures. Zero decoder-drop counters do not establish smooth physical output; provider blame needs
  actual transport evidence. Do not erase failures by widening watchdogs or treating retries as success.
- Remaining sustained DV/NNTP/frame-pacing and device-specific recovery reports are unverified,
  not declared fixed. A new trace may identify further implementation work.

## 2. Finish live account and add-on convergence acceptance

Exercise website -> TV -> phone -> Mac install, reorder, remove, reinstall and restart with the same
account; then switch accounts during pending work. Check library/CW, explicit watch/unwatch, Home
rail order and backup/restore independently. Successful website page readback is not this journey.
Capture any failing URL/QR/Stremio-import operation before changing its proven ownership fences.

## 3. Implement safe Android recovery for quarantined legacy edits

Provide an owner-confirmed inspect/reapply/clear flow for unsynced legacy add-on edits lacking an
exact-owner marker. Keep records recoverable. Never infer ownership from lowercased account IDs,
a shared native UID or a signed-out bucket. Cloud sync cannot reconstruct an edit never uploaded.

## 4. Extend genuine account history to supported custom provider identities

The typed native account-library path currently accepts movie/series IMDb and TMDB identities.
Design and test provider-qualified custom/anime identity ownership before expanding that boundary.
Preserve opaque peer rows; do not fabricate IMDb/TMDB IDs or turn CW into saved membership.

## 5. Complete Android's feature and visual parity

Use the [active parity record](../ANDROID-TV-APPLE-PARITY-PLAN.md), comparing the same title/account
with Apple TV. Finish Home/hero, Detail/actions/sources, episode navigation, Settings/Search/dialogs,
Back and focus restoration. Validate Full and Play on physical phone, Shield/Android TV and Fire TV,
including audio/HDR, remote reachability, orientation, process death and sustained binge playback.
Remaining broader products include the full Local/Trakt/SIMKL selector, SIMKL calendar/custom-list
and recommendation work, and multi-device/remote download ownership. Do not promise unavailable
passthrough or player capabilities merely to match a setting label.

## 6. Finish the Apple visual work and other scoped product gaps

The Mac sidebar/in-window Settings and phone hero seam are delivered source, not an all-screen
redesign. Compare and finish remaining Mac and touch-first phone screens, long labels, accessibility
and artwork fallbacks. Keep libmpv PiP, genre-data coverage, localization, hardware passthrough limits
and a Windows artifact separately scoped; they are not complete by implication.

## Completion standard

Make bounded changes against current source, test deterministic failure paths, independently review
consequential diffs and verify exact packaged content. Close a GitHub report only with evidence for
its actual symptom. Keep unimplemented features separate from implemented-but-device-unverified
behavior, and publish only after the real package/signing/feed gates pass.
