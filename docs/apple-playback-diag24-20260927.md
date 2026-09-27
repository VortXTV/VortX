# Apple playback: overnight diagnostic 24, 27 September 2026

## Full-file coverage

Three read-only readers covered lines 1–6,500, 6,501–13,000 and 13,001–18,757. Oversized tool outputs were reread in bounded chunks. The final record ends with a newline. The private raw file is not committed.

The current dated run is a healthy Debridio → libmpv control: from 05:29:33 at position 6,517/9,813 to 06:24:29 at 9,813/9,813. Hardware decoding remains VideoToolbox, sampled output/decoder drops are zero, and the cache remains populated. The EOF at 06:24:30 is at the known ending, followed by player teardown and a home trailer; this is not evidence of a premature episode completion. No AIOStreams playback run appears in this capture.

The embedded persistent-log snapshot begins at physical line 18,080. Its older 03:43 fallback reaches an MPV first frame with a 171.815-second recovery target; the initiating AVPlayer error is no longer present. Do not treat that snapshot as a new failure after the later foreground records. Decoder errors after the movie's EOF belong to the idle/trailer period. The later background/wake gap and successful loopback listener rebind do not establish why the OS went idle.

## Additional source correction

The same incomplete progressive-thumbnail upload is reconsidered on every real-duration clock tick. The first 6,500 lines alone contain 4,920 identical gate skips for 13 frames with no new coverage. `configureCommunity` now reconsiders an unchanged key only when duration first becomes real; fresh captured frames, a newly selected key, and teardown retain their own admission checks. This avoids redundant UI-thread work and diagnostic flooding without hiding an upload failure or suppressing new coverage. The healthy video counters do not support claiming this flood caused the reported freezes.

The strict-concurrency standalone upload-policy suite passes 1,169 assertions, including 14,400 repeated duration ticks and source-wiring checks. An independent reader reviewed the capture/teardown paths.

## AIOStreams versus Debridio

The user's differential remains important; it is not an upstream-outage diagnosis. Current-source review found no proven raw/proxied URL/header tuple corruption: MPV derives its proxy without replacing the raw active URL, AVPlayer receives the raw URL and matching headers, and native-debrid fresh-link recovery is limited to sources with its own resolver reference. Prepared remux adoption is fenced by URL/header identity.

Header-bearing HLS has different AVPlayer and MPV routes, but the available capture does not prove failed header inheritance or an identical underlying file. No speculative force-MPV policy was added. The capacity, ownership, recovery and idle-prevention repairs documented in the diagnostic 21–23 receipt remain the concrete playback changes in this release. A source-read gap is not evidence that TorBox was down.

## Packaging correction

The secretless CI stub generator flattened both engine module maps into the same destination and made Xcode reject the build. VortxEngine now mirrors the real `Headers/vortx` layout. Full tvOS simulator validation uses the arm64 architecture actually provided by the pinned NodeMobile artifact, matching the protected release smoke lane; Lite retains the separate Intel simulator link check. Both engine-symbol checks and the strict prohibition on shipping stubs remain. Isolated stub generation and orchestration contracts pass. Android SDK bootstrap failures are separate from this Apple-only cut; no Android artifact is represented as newly built.

## Validation boundary

These receipts establish source defects, regression tests and build results, not an overnight test of the new IPA on a physical Apple TV. The new release must come from the current reviewed source and configured protected build lane, not a reused executable. Check DV through repeated rolling-window advances, pause/seek recovery, player changes, next episodes from Continue Watching and screen wake prevention on the resulting build.
