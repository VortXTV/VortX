# Diagnostic 21: next-episode warmup and rejected-source pause

## Coverage

All 17,681 physical lines of the supplied diagnostic were read across bounded, read-only agents. Truncated output did not count: missing ranges were reread in individual numbered chunks. Final union is 1–17,681, including the repeated application-diagnostic section and the streaming-server tail. No raw credentials or full provider URLs are reproduced here.

## Changes

- **tvOS 32 MiB prewarm was rejected by its own 16 MiB validator.** The HTTP Range had been raised to 32 MiB, but `BoundedRangeWarmup.fetch(request)` retained its default 16 MiB acceptance limit. A correct response covering the requested range failed before its body was consumed. The tvOS caller now passes the same explicit byte limit used by its Range header; other callers retain the existing default.
- **Short-preview rejection forced pause onto the replacement.** Both Apple player surfaces paused the rejected asset before synchronously hopping to another source. libmpv retains pause across `loadfile`; the property callback could also contaminate incoming episode intent. Successful hops now avoid that implementation pause. A real viewer pause is captured before the hop and reapplied after admission (including AVPlayer, which resets play intent for a new URL). Terminal mismatch still pauses. No forced unconditional play was added.

## What the log proves

- At 01:07:33 and 01:28:55, prepared Debridio sources were admitted and then rejected by the asset-sanity check. The latter advertised a 30-second, 1-fps, 1280×720 asset rather than the expected episode. The diagnostic phrase `rejected mismatched asset token=` identifies the rejected active load; it is **not** evidence of a token-owner mismatch.
- The first replacement reached a frame at 01:07:38, then stalled near 3 seconds with 706 seconds buffered. The later replacement remained near zero despite successful loading. The synthetic-pause defect is a concrete code path consistent with these buffered-but-frozen replacements; the patch is not an on-device replay of them.
- At 02:28:15, a prepared local NNTP source returned `unrecognized file format` on three attempts. Usenet recovery reported unavailable at 02:28:54, and another source reached its first frame at 02:29:17: roughly 62.5 seconds after initial admission. The generic `service=torBox` label does not prove torrent recovery: local Usenet references use that service tag, while current code dispatches through explicit Usenet provenance.
- The corresponding server tail opens the prepared NNTP stream, retires connections after approximately 30 seconds without a reader, then sees playback retries. Retry-associated event-loop lag briefly reaches 627 ms and 169 ms; ordinary heartbeat lag is about 0–3 ms. This does not prove a permanent server hang or establish why the later media response was invalid.
- Long stretches show healthy hardware-decoded playback, zero decoder/output-drop deltas, and substantial cache headroom. Startup/display drops are present, but no universal decoder-starvation conclusion follows.
- Other observations include a trailer format failure, TorBox **search** DNS errors (`-1003`), and two failed artwork requests (404/525). Search failure is not proof that TorBox playback is generally down. The next launch reports a prior background termination as **likely** jetsam; the log is not a kernel crash report. A multi-hour cache-flush elapsed value spans background suspension, not proven multi-hour foreground execution.
- Routine exit invalidation, deferred contributions, partial trickplay coverage, and `settledDeadline raw=0/0` are not by themselves bugs or evidence of an empty usable source list.

## AVPlayer subtitle-background report

The newly reported background problem remains open. Outline/shaded/box share the same persisted key and invoke the native and external renderers live. Native rules currently clear both enclosing and character backgrounds; external overlay styles have distinct visible mappings. Apple's `AVPlayerItem.textStyleRules` documentation restricts those rules to WebVTT, so generic embedded-track styling is not guaranteed. This diagnostic's explicit playback routes are libmpv (DV remux is enabled by default, but these logged routes report `isDV=false`); it does not identify the AVPlayer subtitle format that ignored the viewer's setting. Do not claim the background is fixed or that a system accessibility setting caused it without a matching AVPlayer capture.

## Verification and limits

- New source-contract regression failed before the patch and passed afterward on both Apple surfaces.
- `BoundedRangeWarmupTests`: 21/21, including 32 MiB response acceptance and real URLSession redirect/header isolation.
- `DiagnosticPlaybackIntegrityPolicyTests`: 105/105.
- `NextEpisodePreloadPolicyTests`: 72 checks passed.
- Real synthetic NNTP wire/router tests passed raw, 7z and RAR streaming, byte ranges, seek, cancellation, idle reopen, and two-provider failover. Those fixtures do not prove live-provider sustained throughput.
- Changed Swift surfaces parse successfully; no full app archive or physical Apple TV run was performed in this session.
- Independent native Terra review of the revised source and regression test found no commit blockers; real-pause preservation was added during review. Native background-rule construction tests also pass, but do not verify rendered appearance.
- OpenCode Go DeepSeek v4 Pro bounded review produced no response before its 120-second deadline; it is not a review receipt. The in-app ChatGPT browser was unavailable. Native independent review owns the actual patch review.

Remaining: verify real next-episode playback with the patched build; diagnose any continuing local-NNTP invalid-response/idle-reopen failure; implement and validate reliable native subtitle appearance without reintroducing duplicate rendering. No release is represented by this source patch.
