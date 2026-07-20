# libvortx_ffi.so (vortx-core JNI cdylib)

This directory holds the prebuilt `libvortx_ffi.so` per ABI (`arm64-v8a/`, `x86_64/`), the OWN
vortx-core engine's JNI surface. ONE .so carries BOTH Kotlin bridges:

* `com.vortx.android.engine.VortxCore` - the kernel bridge powering the shadow-ranking lane
  (`VortxRankingShadow`, flag `vortx.engine.shadowRanking`, default OFF), engine cutover
  Phase 7 slice 1.
* `com.vortx.android.engine.VortxServer` - the IN-PROCESS STREAMING SERVER lifecycle (the
  vortx-core rqbit embed), which is what plays a RAW torrent (no debrid key) on Android:
  `EngineStremioRepository.resolve` hands the player
  `http://127.0.0.1:PORT/{infoHash}/{fileIdx}` served by this server. Kill-switch flag
  `vortx.engine.torrentStreaming`, default ON (serving beats the old "not wired" throw).

The `.so` binaries are gitignored (see `android/.gitignore`); only this README is tracked.
`src/main/jniLibs` is AGP's default jniLibs source set, so any `.so` staged here is packaged
into the APK automatically. An APK built WITHOUT the `.so` still works: both bridges load the
library lazily and fail-safe (`isAvailable()`), the shadow lane stays idle, and raw torrents
surface the clear "needs a debrid key or the streaming server" error instead.

## Build step

The source is NOT in this repository at the needed revision: it is the engine branch's
`vortx-core` workspace (`engine/vortx-core`, crate `crates/ffi`, features `jni,server`). The
vendored `vortx-core/` in this tree carries the kernel crates only (no `ffi`/`streaming-server`).

Preferred: let gradle build it. Point the build at an engine checkout and every assemble
produces + packages the .so (task `cargoNdkBuildVortxFfi` in `android/app/build.gradle.kts`,
modeled on the `cargoNdkBuild` block; it warn-skips when unset so non-Rust machines still build):

```sh
export VORTX_ENGINE_CORE_DIR=<engine-branch-checkout>/vortx-core   # or -Pvortx.engine.coreDir=...
./gradlew :app:assembleFullDebug
```

Manual equivalent, with the Android NDK + `cargo-ndk` + the Rust Android targets installed:

```sh
cd <engine-branch-checkout>/vortx-core
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"   # match android/app ndkVersion
export CARGO_TARGET_DIR=<engine-branch-checkout>/vortx-core/target-andx  # keep the checkout's target/ clean
cargo ndk -t arm64-v8a -t x86_64 -p 26 \
  -o <this-repo>/android/app/src/main/jniLibs \
  build -p vortx-ffi --no-default-features --features jni,server --release
```

Notes:

* `--no-default-features --features jni,server` builds the kernel JNI surface
  (`Java_com_vortx_android_engine_VortxCore_*`) PLUS the server lifecycle
  (`Java_com_vortx_android_engine_VortxServer_*`) over `vortx-streaming-server::embed`. The
  `host` substrate (tokio/reqwest fetch seams) stays excluded: the app owns its networking
  (OkHttp) exactly like the Swift bridge.
* Verify the server surface made it in:
  `llvm-nm -D --defined-only arm64-v8a/libvortx_ffi.so | grep VortxServer` must list the four
  `nativeStart/nativePort/nativeBaseUrl/nativeStop` exports.
* `-p 26` matches the app `minSdk`; the NDK version matches `ndkVersion` in
  `android/app/build.gradle.kts`.
