# Apple startup playback follow-up — 11 September 2026

The user retested an older local IPA and reported a roughly ten-second start and startup/intermittent frame drops. These changes extend current main; no older source or executable was restored.

## Fixed paths

- **Unnecessary initial decoder reset:** the first valid layout used to unconditionally set `vid=no`, then `vid=auto`, even when the drawable was already valid at initialization. The drawable is now explicitly sized before mpv initialization/loading. Already-valid surfaces do not disable/re-enable video at first layout. Genuinely unsized embedded surfaces retain their one-shot recovery. Backing-scale changes use the patched MoltenVK resize/wake path rather than restarting the decoder.
- **Missing hardware compatibility fallback:** devices now request direct VideoToolbox followed by VideoToolbox copy-back before accepting software decoding. Direct rendering stays first. Explicit decoder launch overrides are preserved; simulators stay direct-only because their CPU-to-GPU upload crash is a separate known constraint. Unsupported codecs can still require software; this does not manufacture hardware support or change the AVPlayer/DV routing policy.

mpv documents the ordered decoder list and copy-back mode in its [hardware decoding reference](https://mpv.io/manual/stable/#options-hwdec).

## Evidence and verification

- The existing diagnostic records first position 10.010 seconds with resume zero and auto-skip off. No application seek precedes that event. The same source later reports software decoding at 3840×2160. Neither observation establishes why that exact source lost its opening frames.
- The real shipped libmpv regression harness plays generated media: its default rebases a positive container origin to a near-zero initial position, resumes at seven seconds, and seeks back to zero. A deliberate `rebase-start-time=no` control reproduces a positive initial position. A timestamp offset alone therefore does not explain the field failure under normal settings.
- The same harness deliberately removes direct surface-import support with a null VO. Direct-only VideoToolbox falls to software; the ordered decoder list successfully negotiates `videotoolbox-copy`. This proves the previously skipped fallback is usable, not that the reported tvOS source failed specifically at Metal import.
- 24 compiled surface-policy/wiring checks and 18 compiled hardware-policy/wiring checks pass. The real libmpv harness passes eight assertions. Test media and binaries remain outside the repository under the canonical recovery directory.
- Independent Terra source/artifact review found no blocker after verifying the regenerated Xcode project's source entries and executing both compiled policy suites.
- Full unsigned tvOS Release and macOS arm64 Debug builds pass from the final source. The local test artifact is tvOS only; this is not an Intel Mac verification or a new iOS package.

## Device verification still required

The exact ten-second field start and intermittent physical Apple TV frame pacing are not claimed universally resolved by these changes. Test the newly identified IPA with a fresh episode, next episode, resume, backward seek and pause/play. The `vo-start` and `vo-initial-rebuild` receipts distinguish an actually unsized startup from the removed unnecessary reset; existing first-position, codec/pixel-format and negotiated-decoder receipts distinguish the playback paths. A long-running live-provider soak is separate from the synthetic decoder/timeline regression test.

No public release is implied by this source patch.
