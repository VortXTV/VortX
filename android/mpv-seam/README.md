# :mpv-seam -- the VortX source-built libmpv JNI seam

This module replaces the published `dev.jdtech.mpv:libmpv:1.0.0` AAR's JNI glue (`libplayer.so`).
The original reason was its loss of `mpv_event_end_file` payloads, which prevented Android from
distinguishing natural EOF from error, stop, quit, or redirect. The source seam now also owns the
native handle and Surface lifetime hardening needed for safe rapid Back and SurfaceHolder churn.

## What is forked, from where, under which license

The glue (all files under `src/main/cpp/` plus `MpvSeam.kt`) is forked from
[jarnedemeulemeester/libmpv-android](https://github.com/jarnedemeulemeester/libmpv-android) at tag
**v1.0.0** -- commit `fcf6745` ("ci: update publish workflow"; its parent `cca0417` ("chore: bump
version to 1.0.0") differs only in that CI workflow, so every `libmpv/` file is identical at
either commit) -- the same upstream version as the AAR artifact VortX already consumed, so
behavior parity is reviewable line-by-line. Upstream ships it under the **MIT** license; the
verbatim license text is in [`LICENSE`](LICENSE).

## The complete upstream delta inventory

Every intentional difference between upstream tag v1.0.0 and this module is categorized below.

**Event protocol (the W1-B patch):**

1. **END_FILE payload seam.** `event.cpp`: an explicit `MPV_EVENT_END_FILE` case reads
   `struct mpv_event_end_file` and calls the new `MpvSeam.eventEndFile(reason, error)` dispatcher
   via a new cached method id (`seam_MpvSeam_eventEndFile_II`, `jni_utils.*`). `reason` is forwarded
   verbatim (client.h says unknown values must be treated as unknown); `error` is forwarded only
   when reason == `MPV_END_FILE_REASON_ERROR` and is 0 otherwise (client.h documents the field as 0
   in all other cases). FIFO event ordering through mpv's per-client queue is untouched, so Kotlin
   can keep binding its replacement-suppression window to START_FILE. Kotlin side: the matching
   dispatcher + `EventObserver.eventEndFile(reason, error)` interface method were added.

**Lifecycle and malformed-payload hardening:**

2. **Linearized and callback-safe native destruction.** `MpvNativeHandleGate` leases the pointer to
   every JNI call, rejects new leases after destruction starts, waits for existing calls, and destroys
   exactly once. Reentrant destroy calls return without waiting. Listener-requested teardown is moved
   off the JNI callback stack; native code independently transfers final cleanup to the event loop and
   frees the instance only after `CallVoidMethod` unwinds. A startup handshake publishes the pthread id
   and completes `nativeInit` before the child can dispatch callbacks. This closes the check-then-free,
   startup-publication, and event-thread self-join/use-after-free paths.
3. **Single-owner Surface lifetime.** Kotlin serializes attach, detach, and destroy. Native attach
   replaces a GlobalRef without leaking the old one, detach is idempotent, and final destroy owns any
   residual ref. A late SurfaceHolder callback therefore cannot double-delete or use a freed instance.
4. **Partial-create and payload guards.** Native creation releases GlobalRefs on failure. Property,
   log, and end-file dispatch drop null/malformed payloads instead of dereferencing them.

**API-surface adaptation (Kotlin constants/interfaces only; no dispatch behavior):**

5. `object MpvLogLevel` (the eight `MPV_LOG_LEVEL_*` constants) from upstream is NOT carried: VortX
   registers no log observers, and the native side still requests/dispatches log messages exactly as
   upstream does.
6. `object MpvEndFileReason` added (EOF=0, STOP=2, QUIT=3, ERROR=4, REDIRECT=5 from the vendored
   client.h) documenting the values `eventEndFile` delivers.
7. Library load list changed from `System.loadLibrary("mpv"); System.loadLibrary("player")` to
   `"mpv"` then `"vortx_mpv_seam"`: the AAR still supplies libmpv.so, but the glue itself is this
   module's source-built library, not the AAR's libplayer.so.

**Mechanical renames (no semantic change):**

8. Package/class `dev.jdtech.mpv.MPVLib` -> `com.vortx.android.player.mpv.seam.MpvSeam`; JNI symbols
   `Java_dev_jdtech_mpv_MPVLib_*` -> `Java_com_vortx_android_player_mpv_seam_MpvSeam_*`; cached
   method-id globals renamed with a `seam_` prefix; FindClass string updated to match; logcat tag
   `mpv` -> `VortxMpvSeam`; `checkCreated()` exception text "MPVLib is not initialized" ->
   "MpvSeam is not initialized"; the consumer R8 keep rule targets the new class name.

**Compile-time substitution (link behavior unchanged):**

9. `main.cpp` replaces upstream's `#include <libavcodec/jni.h>` with exact extern-"C" prototypes of
   the two symbols it uses (`av_jni_set_java_vm`, `av_jni_set_android_app_ctx`, verbatim FFmpeg 8.1
   signatures), so the LGPL header is not vendored. Both still link from libavcodec.so.

**Build configuration (VortX-native; not upstream code):**

10. `CMakeLists.txt` is rewritten for this repo rather than carried: project/target name
   `vortx_mpv_seam`, imported prebuilts resolved from `${MPV_AAR_JNI_DIR}` (the Gradle-extracted AAR
   libs) with fail-closed configure-time existence checks, and the vendored-header include dir --
   versus upstream's buildscripts-prefix paths and its `player` target name.
11. `build.gradle.kts` is VortX-native (AGP/Kotlin plugins from our version catalog, no maven
   publishing): NDK pinned to the app-wide pin `27.2.12479018` (upstream builds with NDK 29),
   CMake 3.22.1 (upstream pins 4.1.2), and `-DANDROID_STL=c++_static` instead of upstream's
   `c++_shared` -- this glue is self-contained C++ (JNI primitives + mpv's C API cross its
   boundary), so it adds no second `libc++_shared.so` copy to the APK.
12. A minimal `src/main/AndroidManifest.xml` was added (upstream's published artifact generates one);
    `consumer-rules.pro` carries only the retargeted keep rule.

**Files not derived from upstream at all:** `include/mpv/client.h` / `include/mpv/stream_cb.h`
(verbatim mpv v0.41.0, ISC), both README files, and `LICENSE`.

Everything not listed above in `main.cpp`, `event.*`, `property.cpp`, `render.cpp`, `log.cpp`,
`jni_utils.*`, `globals.h`, and `MpvSeam.kt` remains upstream v1.0.0 behavior.

## Supply chain: what is built vs consumed

- **Built from source here:** only the thin glue, `libvortx_mpv_seam.so`.
- **Never rebuilt or vendored:** libmpv + ffmpeg. The heavy `.so` set still comes exclusively from
  the pinned `dev.jdtech.mpv:libmpv:1.0.0` Maven artifact (same coordinate, version catalog pin,
  and licensing confinement to the `full` flavor as before). The module resolves that same AAR at
  build time ONLY to extract `libmpv.so` / `libavcodec.so` as linker inputs
  (`extractMpvAarJniLibs` task); nothing lands in git, nothing extra is packaged.
- `src/main/cpp/include/mpv/*.h` are the public client-API headers copied verbatim from mpv tag
  `v0.41.0` -- the exact release bundled inside the AAR (see `include/mpv/README.md`; ISC license).
  Compile-time inputs only.
- At runtime `MpvSeam` loads `libmpv.so` (from the AAR) then `libvortx_mpv_seam.so`. It never loads
  the AAR's own `libplayer.so`; the app packaging excludes that now-dead binary.

## Why a source-built fork instead of extending the artifact class

The artifact's callbacks are wired inside its prebuilt `libplayer.so` (cached JNI method ids, fixed
signatures). There is no supported way to enrich `event(int)` with payload data without replacing
that library; and replacing opaque binaries would be worse than replacing them with auditable
source. This fork keeps every line of the bridge inspectable and patchable in-tree while leaving
the actual media engine binaries on their existing supply chain.
