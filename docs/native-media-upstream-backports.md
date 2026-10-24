# Selected custom-mpv upstream backports

The Apple and Android candidate builders retain the coupled custom source
family: mpv `8c67647b50059406c5c0444903597281b81516cf`, libplacebo
`4c426e466814536def653cb23f1d1c287ea7a7f5` and FFmpeg `9.0.2` /
`946fcce07b6dcd0331c8cc609192aeff5e1924f8`. The Android dependency recipe
matches the already selected component's producer rather than reverting to an
older stable source family. Historical component manifests are not rewritten.

Two maintained patch files add three narrowly selected upstream fixes:

| Upstream change | Benefit and scope |
| --- | --- |
| [AAudio retry bounds](https://github.com/mpv-player/mpv/commit/3b276cef9b74fa78d38ebe02a4fe7150cc252138) | Prevents reading beyond the channel-count retry table when every Android AAudio attempt is out of range. |
| [AudioUnit layout validation](https://github.com/mpv-player/mpv/commit/01a7420cbb4bfcb3ae275b864a8a734c61ee8831) | Rejects oversized channel layouts before copying them and maps unknown speaker labels to the existing not-applicable sentinel. This affects the iOS/tvOS AudioUnit fallback, not every Apple audio output. |
| [gpu-next deferred seek reset](https://github.com/mpv-player/mpv/commit/3186d369f9f090cd1363be0ac46a037824b702c6) | Retains the previous queue for redraw while a seek is pending, resetting it when the first genuinely new frame arrives. It is not proof of the cause of a specific pause or EOF incident. |

`mpv-upstream-audio-layout-bounds.patch` contains the first two changes;
`mpv-upstream-gpu-next-seek-reset.patch` contains the third. Both builders apply
them after their existing custom HTTP-interruption patch. The Apple builder
also retains its existing DV/FEL, MoltenVK and CoreAudio lifecycle patches.
The hosted input inventory binds all patch bytes and both candidate jobs bind
that inventory's digest.

This is candidate-source integration, not a binary upgrade. The selected
application AAR and Apple native artifacts remain unchanged until fresh native
builds, corresponding-source/provenance inspection, ABI/minimum-OS checks,
platform and physical-device acceptance, and package/release gates pass. Never
relabel an old artifact as having these backports.

Use a fresh hosted candidate checkout. Existing dirty Apple caches containing
only the previous patch set intentionally fail exact-tree validation; do not
reset them or relax that guard to force incremental reuse. Android's
commit-identity check likewise does not certify an arbitrary dirty dependency
cache.

Release or asset metadata changes are monitoring signals, not source fixes.
Each adoption needs its actual diff, prerequisites, interaction with our custom
patches, and bounded regression evidence. A full upstream rebase, dependency
upgrade or HLS/DASH cancellation change is not implied by these three
backports.

Focused verification covers 26 candidate-recipe contracts and 27 extracted-C
scenarios under AddressSanitizer/UndefinedBehaviorSanitizer. The original source
reproduces the retry-table read and oversized-layout write; the patched variants
pass and preserve the asserted audio/queue behavior. These use disclosed
synthetic channel/queue collaborators, not real Android/Apple output, complete
libplacebo execution, extreme frame IDs or physical playback acceptance.
