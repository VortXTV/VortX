# libvortx_ffi.so (vortx-core JNI cdylib)

This directory holds the prebuilt `libvortx_ffi.so` per ABI (`arm64-v8a/`, `armeabi-v7a/`,
`x86_64/`), the OWN vortx-core engine's JNI surface consumed by
`com.vortx.android.engine.VortxCore`. It powers the shadow-ranking lane
(`VortxRankingShadow`, flag `vortx.engine.shadowRanking`, default OFF), engine cutover
Phase 7 slice 1.

The `.so` binaries are gitignored (see `android/.gitignore`); only this README is tracked.
`src/main/jniLibs` is AGP's default jniLibs source set, so any `.so` staged here is packaged
into the APK automatically. An APK built WITHOUT the `.so` still works: `VortxCore` loads the
library lazily and fail-safe, and the default-OFF flag means the lane never runs anyway.

## Build step (manual, until the engine branch merges into this tree)

The source is NOT in this repository at the needed revision: it is the engine branch's
`vortx-core` workspace (`engine/vortx-core`, crate `crates/ffi`, feature `jni`). The vendored
`vortx-core/` in this tree does not carry the `jni` feature yet. From a checkout of the engine
branch, with the Android NDK + `cargo-ndk` + the Rust Android targets installed:

```sh
cd <engine-branch-checkout>/vortx-core
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"   # match android/app ndkVersion
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 -p 26 \
  -o <this-repo>/android/app/src/main/jniLibs \
  build -p vortx-ffi --no-default-features --features jni --release
```

Notes:

* `--no-default-features --features jni` builds the KERNEL-ONLY cdylib (the 7-symbol C ABI plus
  the `Java_com_vortx_android_engine_VortxCore_*` JNI twins). The `host`/`server` substrate
  (tokio/reqwest/rqbit) is deliberately excluded from the Android slice for now: the app owns
  its networking (OkHttp) exactly like the Swift bridge.
* `-p 26` matches the app `minSdk`; the NDK version matches `ndkVersion` in
  `android/app/build.gradle.kts`.
* When the engine branch's `vortx-core` lands in this tree, replace the manual step with a
  gradle `Exec` task modeled on the existing `cargoNdkBuild` block in
  `android/app/build.gradle.kts` (same pattern, different crate + features + output dir).
