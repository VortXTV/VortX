#!/usr/bin/env bash
# SKELETON (Phase 4): build the vortx-ffi staticlib for the Apple platforms and package it as an
# .xcframework, mirroring the shipping bridge's scripts/build-core-xcframework.sh one level up.
# Not run in CI yet: it needs Xcode + the Apple rustup targets installed (see REQUIREMENTS).
#
# REQUIREMENTS
#   - Rust nightly with rust-src (the workspace rust-toolchain.toml already pins this):
#       rustup component add rust-src --toolchain nightly
#   - Apple targets: rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim
#     (tvOS is tier-3: no prebuilt std, hence -Z build-std below; iOS/macOS could use the
#     prebuilt std, but every slice builds with panic_abort std so no panic can ever unwind
#     across the C boundary, and so the macOS slice stays linkable next to MPVKit's Libdovi,
#     which also defines _rust_eh_personality.)
#   - Xcode with the iphoneos / iphonesimulator / appletvos / appletvsimulator / macosx SDKs.
#
# ANDROID (cdylib, one-liner per ABI; needs the NDK + cargo-ndk):
#   cargo ndk -t arm64-v8a -t x86_64 -o android/app/src/main/jniLibs \
#     build -p vortx-ffi --release
#   (Without cargo-ndk: rustup target add aarch64-linux-android, point CC/AR/linker at the NDK
#   toolchain in .cargo/config.toml, then cargo build -p vortx-ffi --release --target
#   aarch64-linux-android; the artifact is target/<triple>/release/libvortx_ffi.so.)
#
# WASM (pure kernel ABI only; the host feature needs tokio + reqwest, which wasm32 has no
# substrate for, so it is switched off):
#   cargo build -p vortx-ffi --no-default-features --release --target wasm32-unknown-unknown
#   (The web host then imports the exported vortx_* symbols from the .wasm module; the JS glue
#   owns fetch/storage exactly like the Swift/Kotlin bridges do.)
set -euo pipefail
cd "$(dirname "$0")/.."   # vortx-core workspace root
source "$HOME/.cargo/env" 2>/dev/null || true

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libvortx_ffi.a"
HEADERS="crates/ffi/include"
OUT="target/xcframework/VortxEngine.xcframework"

rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "- tvOS device (aarch64-apple-tvos)"
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)" \
  cargo +nightly build $BUILDSTD -p vortx-ffi --target aarch64-apple-tvos --release

echo "- tvOS simulator (aarch64-apple-tvos-sim)"
SDKROOT="$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  cargo +nightly build $BUILDSTD -p vortx-ffi --target aarch64-apple-tvos-sim --release

echo "- iOS device (aarch64-apple-ios)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  cargo +nightly build $BUILDSTD -p vortx-ffi --target aarch64-apple-ios --release

echo "- iOS simulator (aarch64-apple-ios-sim)"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  cargo +nightly build $BUILDSTD -p vortx-ffi --target aarch64-apple-ios-sim --release

echo "- macOS (aarch64-apple-darwin)"
cargo +nightly build $BUILDSTD -p vortx-ffi --target aarch64-apple-darwin --release

# The macOS slice links into the same app as MPVKit's Libdovi (also Rust), which exports its own
# _rust_eh_personality; the macOS linker rejects the duplicate. Partial-link the archive into one
# object with that symbol made local, then re-archive (same treatment the shipping bridge needs).
DARWIN="target/aarch64-apple-darwin/release"
ld -r -arch arm64 -platform_version macos 14.0 14.0 -all_load "$DARWIN/$LIB" \
  -unexported_symbol _rust_eh_personality -o "$DARWIN/vortx_ffi_localized.o"
rm -f "$DARWIN/$LIB"
libtool -static -o "$DARWIN/$LIB" "$DARWIN/vortx_ffi_localized.o"

echo "- packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers "$HEADERS" \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers "$HEADERS" \
  -library "target/aarch64-apple-ios/release/$LIB"      -headers "$HEADERS" \
  -library "target/aarch64-apple-ios-sim/release/$LIB"  -headers "$HEADERS" \
  -library "target/aarch64-apple-darwin/release/$LIB"   -headers "$HEADERS" \
  -output "$OUT"
echo "OK: $OUT (tvOS + iOS + macOS slices)"
