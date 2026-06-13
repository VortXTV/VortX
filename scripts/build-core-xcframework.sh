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

# macOS slice is intentionally omitted for now: Mac Catalyst is blocked upstream (MPVKit 0.41.0
# ships no maccatalyst slice for Libuavs3d/Libluajit), and the native-macOS path (aarch64-apple-
# darwin slice + an AppKit player port) is a separate tracked effort. Add the darwin slice here
# when that work starts.
echo "▸ packaging $OUT"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-tvos/release/$LIB"     -headers include \
  -library "target/aarch64-apple-tvos-sim/release/$LIB" -headers include \
  -library "target/aarch64-apple-ios/release/$LIB"      -headers include \
  -library "target/aarch64-apple-ios-sim/release/$LIB"  -headers include \
  -output "$OUT"
echo "OK: $OUT (tvOS + iOS slices)"
