#!/usr/bin/env bash
# Build the Rust `stremiox-core` FFI crate for tvOS and iOS (device + simulator) and package it as an
# .xcframework the Xcode apps link (like NodeMobile). Requires: Rust nightly + rust-src, Xcode.
#   tvOS is a tier-3 Rust target, so std is built from source via -Z build-std.
#   iOS is tier-2, so its std is prebuilt: just add the targets, no build-std.
set -euo pipefail
cd "$(dirname "$0")/../core"
source "$HOME/.cargo/env" 2>/dev/null || true

BUILDSTD="-Z build-std=std,panic_abort"
LIB="libstremiox_core.a"
OUT="../app/Vendor/StremioXCore.xcframework"   # Vendor/ is gitignored; produced by this script

rustup +nightly target add aarch64-apple-ios aarch64-apple-ios-sim 2>/dev/null || true

echo "▸ tvOS device (aarch64-apple-tvos)"
SDKROOT="$(xcrun --sdk appletvos --show-sdk-path)" \
  cargo +nightly build $BUILDSTD --target aarch64-apple-tvos --release

echo "▸ tvOS simulator (aarch64-apple-tvos-sim)"
SDKROOT="$(xcrun --sdk appletvsimulator --show-sdk-path)" \
  cargo +nightly build $BUILDSTD --target aarch64-apple-tvos-sim --release

echo "▸ iOS device (aarch64-apple-ios)"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)" \
  cargo +nightly build --target aarch64-apple-ios --release

echo "▸ iOS simulator (aarch64-apple-ios-sim)"
SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  cargo +nightly build --target aarch64-apple-ios-sim --release

# Native macOS slice for the Mac app (NOT Catalyst, which MPVKit can't link). Built with the same
# build-std=panic_abort as tvOS, NOT the prebuilt (unwinding) std: MPVKit's Libdovi (a Rust lib)
# also defines _rust_eh_personality, and the macOS linker rejects the duplicate against an
# unwinding-std core. A panic=abort std core does not emit the conflicting personality.
echo "▸ macOS (aarch64-apple-darwin)"
cargo +nightly build $BUILDSTD --target aarch64-apple-darwin --release
# MPVKit's Libdovi (also Rust) defines _rust_eh_personality too, and the macOS linker rejects the
# duplicate against our core's global copy (iOS tolerates it). Partial-link the darwin archive into
# one object with that symbol made LOCAL, then re-archive: our refs still resolve in-archive, but it
# no longer exports a clashing global. Only the macOS slice needs this.
DARWIN="target/aarch64-apple-darwin/release"
ld -r -arch arm64 -platform_version macos 14.0 14.0 -all_load "$DARWIN/$LIB" -unexported_symbol _rust_eh_personality -o "$DARWIN/core_localized.o"
rm -f "$DARWIN/$LIB"
libtool -static -o "$DARWIN/$LIB" "$DARWIN/core_localized.o"

echo "▸ packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers include \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers include \
  -library "target/aarch64-apple-ios/release/$LIB"      -headers include \
  -library "target/aarch64-apple-ios-sim/release/$LIB"  -headers include \
  -library "target/aarch64-apple-darwin/release/$LIB"   -headers include \
  -output "$OUT"
echo "OK: $OUT (tvOS + iOS + macOS slices)"
