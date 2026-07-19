#!/usr/bin/env bash
# Build the Rust `vortx-engine` FFI crate (the NEW vortx-core workspace) for tvOS, iOS, and macOS
# and package it as VortXCore.xcframework, exactly parallel to build-core-xcframework.sh which does
# the same for the OLD stremio-core based crate. Requires: Rust nightly + rust-src, Xcode.
#   tvOS is a tier-3 Rust target, so std is built from source via -Z build-std.
#   iOS is tier-2, so its std is prebuilt: just add the targets, no build-std.
#   macOS is built with build-std=panic_abort AND has _rust_eh_personality localized, because
#   MPVKit's Libdovi (also Rust) exports the same symbol and the macOS linker rejects the
#   duplicate (iOS tolerates it). See the OLD script for the original derivation of this trap.
set -euo pipefail
cd "$(dirname "$0")/../vortx-core"
source "$HOME/.cargo/env" 2>/dev/null || true

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libvortx_engine.a"
OUT="../app/Vendor/VortXCore.xcframework"   # Vendor/ is gitignored; produced by this script

rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "==> tvOS device (aarch64-apple-tvos)"
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)" \
  cargo +nightly build -p vortx-engine $BUILDSTD --target aarch64-apple-tvos --release

echo "==> tvOS simulator (aarch64-apple-tvos-sim)"
SDKROOT="$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  cargo +nightly build -p vortx-engine $BUILDSTD --target aarch64-apple-tvos-sim --release

echo "==> iOS device (aarch64-apple-ios)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  cargo +nightly build -p vortx-engine --target aarch64-apple-ios --release

echo "==> iOS simulator (aarch64-apple-ios-sim)"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  cargo +nightly build -p vortx-engine --target aarch64-apple-ios-sim --release

# Native macOS slice for the Mac app (NOT Catalyst, which MPVKit can't link). Built with the same
# build-std=panic_abort as tvOS, NOT the prebuilt (unwinding) std: MPVKit's Libdovi (a Rust lib)
# also defines _rust_eh_personality, and the macOS linker rejects the duplicate against an
# unwinding-std core. A panic=abort std core does not emit the conflicting personality.
echo "==> macOS (aarch64-apple-darwin)"
cargo +nightly build -p vortx-engine $BUILDSTD --target aarch64-apple-darwin --release
# Partial-link the darwin archive into one object with _rust_eh_personality made LOCAL, then
# re-archive: our refs still resolve in-archive, but it no longer exports a clashing global.
# Only the macOS slice needs this (same recipe as the OLD core's script).
DARWIN="target/aarch64-apple-darwin/release"
ld -r -arch arm64 -platform_version macos 14.0 14.0 -all_load "$DARWIN/$LIB" -unexported_symbol _rust_eh_personality -o "$DARWIN/vortx_core_localized.o"
rm -f "$DARWIN/$LIB"
libtool -static -o "$DARWIN/$LIB" "$DARWIN/vortx_core_localized.o"

echo "==> packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers include \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers include \
  -library "target/aarch64-apple-ios/release/$LIB"      -headers include \
  -library "target/aarch64-apple-ios-sim/release/$LIB"  -headers include \
  -library "target/aarch64-apple-darwin/release/$LIB"   -headers include \
  -output "$OUT"
echo "OK: $OUT (tvOS + iOS + macOS slices)"
